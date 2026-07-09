//! inventory-service is the product-inventory HTTP API.
//!
//! Production concerns handled here: fail-fast configuration, structured JSON
//! logging, Prometheus RED metrics, liveness/readiness endpoints, a resilient
//! DB connection with retry/backoff, a request body limit, and graceful
//! shutdown.

mod config;
mod db;
mod handlers;
mod metrics;

use axum::{
    extract::{DefaultBodyLimit, MatchedPath, Request},
    middleware::{self, Next},
    response::Response,
    routing::{get, put},
    Router,
};
use sqlx::postgres::PgPool;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::net::TcpListener;

/// Shared dependencies for the HTTP handlers.
#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub ready: Arc<AtomicBool>,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .json()
        .with_max_level(tracing::Level::INFO)
        .init();
    tracing::info!(version = env!("CARGO_PKG_VERSION"), "starting inventory-service");

    let cfg = match config::Config::from_env() {
        Ok(c) => c,
        Err(e) => {
            // Fail fast on misconfiguration rather than falling back to
            // insecure defaults.
            tracing::error!(error = %e, "invalid configuration");
            std::process::exit(1);
        }
    };

    let pool = match db::make_pool(&cfg) {
        Ok(p) => p,
        Err(e) => {
            tracing::error!(error = %e, "failed to initialise database pool");
            std::process::exit(1);
        }
    };
    metrics::init();

    let ready = Arc::new(AtomicBool::new(false));
    // Connect + migrate in the background with retry so a not-yet-ready
    // database never crash-loops the pod; readiness gates traffic until this
    // succeeds.
    tokio::spawn(init_with_retry(pool.clone(), ready.clone()));

    let state = AppState {
        pool,
        ready,
    };

    let app = Router::new()
        .route("/metrics", get(handlers::metrics))
        .route("/healthz", get(handlers::healthz))
        .route("/readyz", get(handlers::readyz))
        .route("/products", get(handlers::list_products))
        .route("/products/:id", get(handlers::get_product))
        .route("/inventory/:id", put(handlers::update_inventory))
        .layer(middleware::from_fn(track_metrics))
        .layer(DefaultBodyLimit::max(1 << 20)) // 1 MiB
        .with_state(state);

    let addr = format!("0.0.0.0:{}", cfg.port);
    let listener = TcpListener::bind(&addr)
        .await
        .unwrap_or_else(|e| panic!("failed to bind {addr}: {e}"));
    tracing::info!(addr = %addr, "starting server");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .expect("server error");
    tracing::info!("shutdown complete");
}

/// Connects to the database and applies the schema, retrying with capped
/// exponential backoff. Sets the readiness flag once the schema is ready.
async fn init_with_retry(pool: PgPool, ready: Arc<AtomicBool>) {
    let mut backoff = Duration::from_secs(1);
    let max_backoff = Duration::from_secs(30);
    loop {
        let attempt = async {
            sqlx::query("SELECT 1").execute(&pool).await?;
            sqlx::query(db::SCHEMA).execute(&pool).await?;
            Ok::<(), sqlx::Error>(())
        }
        .await;

        match attempt {
            Ok(()) => {
                ready.store(true, Ordering::Relaxed);
                tracing::info!("database ready, schema applied");
                return;
            }
            Err(e) => {
                tracing::warn!(error = %e, backoff = ?backoff, "database not ready, retrying");
                tokio::time::sleep(backoff).await;
                if backoff < max_backoff {
                    backoff = (backoff * 2).min(max_backoff);
                }
            }
        }
    }
}

/// RED-metrics middleware, labelling by the matched route pattern (low
/// cardinality) rather than the raw path.
async fn track_metrics(req: Request, next: Next) -> Response {
    let method = req.method().as_str().to_owned();
    let route = req
        .extensions()
        .get::<MatchedPath>()
        .map(|m| m.as_str().to_owned())
        .unwrap_or_else(|| "unmatched".to_owned());

    let start = Instant::now();
    let resp = next.run(req).await;
    let code = resp.status().as_u16().to_string();

    metrics::HTTP_REQUESTS_TOTAL
        .with_label_values(&[&method, &route, &code])
        .inc();
    metrics::HTTP_REQUEST_DURATION
        .with_label_values(&[&method, &route])
        .observe(start.elapsed().as_secs_f64());
    resp
}

/// Resolves on SIGINT or SIGTERM.
async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut sig) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            sig.recv().await;
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
    tracing::info!("shutdown signal received, draining connections");
}
