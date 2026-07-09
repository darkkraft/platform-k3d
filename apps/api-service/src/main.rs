//! api-service — the order-management HTTP API.
//!
//! Production concerns: fail-fast configuration, structured JSON logging,
//! Prometheus RED metrics, liveness/readiness endpoints, a resilient DB
//! connection with retry/backoff, a bounded pool, and graceful shutdown.

mod config;
mod db;
mod handlers;
mod metrics;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use handlers::AppState;

const VERSION: &str = match option_env!("VERSION") {
    Some(v) => v,
    None => "dev",
};

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .json()
        .with_max_level(tracing::Level::INFO)
        .init();
    tracing::info!(version = VERSION, "starting api-service");

    let cfg = match config::Config::from_env() {
        Ok(c) => c,
        Err(e) => {
            // Fail fast on misconfiguration rather than falling back to insecure defaults.
            tracing::error!(error = e, "invalid configuration");
            std::process::exit(1);
        }
    };

    let pool = db::pool(&cfg);
    let ready = Arc::new(AtomicBool::new(false));

    // Connect + migrate in the background with retry so a not-yet-ready database
    // never crash-loops the pod; readiness gates traffic until this succeeds.
    tokio::spawn(init_with_retry(pool.clone(), ready.clone()));

    let app = handlers::router(AppState {
        db: pool,
        ready,
    });

    let addr = format!("0.0.0.0:{}", cfg.port);
    let listener = match tokio::net::TcpListener::bind(&addr).await {
        Ok(l) => l,
        Err(e) => {
            tracing::error!(error = %e, addr, "failed to bind");
            std::process::exit(1);
        }
    };

    tracing::info!(port = cfg.port, "starting server");
    if let Err(e) = axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
    {
        tracing::error!(error = %e, "server error");
        std::process::exit(1);
    }
    tracing::info!("shutdown complete");
}

async fn init_with_retry(pool: sqlx::PgPool, ready: Arc<AtomicBool>) {
    let mut backoff = Duration::from_secs(1);
    let max_backoff = Duration::from_secs(30);
    loop {
        let result = match db::ping(&pool).await {
            Ok(()) => db::init_schema(&pool).await,
            Err(e) => Err(e),
        };
        match result {
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

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };

    #[cfg(unix)]
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut s) => {
                s.recv().await;
            }
            Err(_) => std::future::pending::<()>().await,
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
