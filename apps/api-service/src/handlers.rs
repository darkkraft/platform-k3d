//! HTTP routes and handlers for the order-management API.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use axum::body::Bytes;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::{header, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use chrono::NaiveDateTime;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sqlx::PgPool;

use crate::{db, metrics};

#[derive(Clone)]
pub struct AppState {
    pub db: PgPool,
    pub ready: Arc<AtomicBool>,
}

#[derive(Serialize, sqlx::FromRow)]
pub struct Order {
    pub id: i32,
    pub product_id: i32,
    pub quantity: i32,
    pub customer_id: String,
    pub status: String,
    pub created_at: NaiveDateTime,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateOrderRequest {
    pub product_id: i32,
    pub quantity: i32,
    pub customer_id: String,
}

impl CreateOrderRequest {
    /// Enforces business rules; returns a client-safe message on failure.
    pub fn validate(&self) -> Option<&'static str> {
        if self.product_id <= 0 {
            return Some("product_id must be a positive integer");
        }
        if self.quantity <= 0 {
            return Some("quantity must be a positive integer");
        }
        if self.customer_id.is_empty() {
            return Some("customer_id is required");
        }
        if self.customer_id.chars().count() > 255 {
            return Some("customer_id must be at most 255 characters");
        }
        None
    }
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/metrics", get(metrics_handler))
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
        .route("/orders", get(list_orders).post(create_order))
        .route("/orders/:id", get(get_order))
        .layer(axum::middleware::from_fn(metrics::track_metrics))
        .layer(DefaultBodyLimit::max(1 << 20)) // 1 MiB
        .with_state(state)
}

fn client_error(code: StatusCode, msg: &str) -> Response {
    (code, Json(json!({ "error": msg }))).into_response()
}

/// Logs the real error and returns a generic message — never leak internal
/// details (SQL, driver errors) to clients.
fn server_error(op: &str, e: sqlx::Error) -> Response {
    tracing::error!(op = op, error = %e, "request failed");
    client_error(StatusCode::INTERNAL_SERVER_ERROR, "internal server error")
}

async fn metrics_handler() -> Response {
    (
        [(header::CONTENT_TYPE, "text/plain; version=0.0.4")],
        metrics::render(),
    )
        .into_response()
}

/// Liveness: the process is up and serving.
async fn healthz() -> Response {
    (StatusCode::OK, Json(json!({ "status": "ok" }))).into_response()
}

/// Readiness: schema applied and the database reachable.
async fn readyz(State(st): State<AppState>) -> Response {
    if !st.ready.load(Ordering::Relaxed) {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "status": "initialising" })),
        )
            .into_response();
    }
    match tokio::time::timeout(Duration::from_secs(2), db::ping(&st.db)).await {
        Ok(Ok(())) => (StatusCode::OK, Json(json!({ "status": "ready" }))).into_response(),
        Ok(Err(e)) => {
            tracing::warn!(error = %e, "readiness check failed");
            db_unavailable()
        }
        Err(_) => {
            tracing::warn!("readiness check timed out");
            db_unavailable()
        }
    }
}

fn db_unavailable() -> Response {
    (
        StatusCode::SERVICE_UNAVAILABLE,
        Json(json!({ "status": "db unavailable" })),
    )
        .into_response()
}

async fn list_orders(State(st): State<AppState>) -> Response {
    let q = "SELECT id, product_id, quantity, customer_id, status, created_at \
             FROM orders ORDER BY created_at DESC LIMIT 100";
    match sqlx::query_as::<_, Order>(q).fetch_all(&st.db).await {
        Ok(orders) => (StatusCode::OK, Json(orders)).into_response(),
        Err(e) => server_error("list orders", e),
    }
}

async fn create_order(State(st): State<AppState>, body: Bytes) -> Response {
    let req: CreateOrderRequest = match serde_json::from_slice(&body) {
        Ok(r) => r,
        Err(_) => return client_error(StatusCode::BAD_REQUEST, "invalid JSON body"),
    };
    if let Some(msg) = req.validate() {
        return client_error(StatusCode::BAD_REQUEST, msg);
    }

    let q = "INSERT INTO orders (product_id, quantity, customer_id, status) \
             VALUES ($1, $2, $3, 'pending') RETURNING id";
    match sqlx::query_scalar::<_, i32>(q)
        .bind(req.product_id)
        .bind(req.quantity)
        .bind(&req.customer_id)
        .fetch_one(&st.db)
        .await
    {
        Ok(id) => (StatusCode::CREATED, Json(json!({ "order_id": id }))).into_response(),
        Err(e) => server_error("create order", e),
    }
}

async fn get_order(State(st): State<AppState>, Path(id): Path<String>) -> Response {
    let id: i32 = match id.parse() {
        Ok(n) if n > 0 => n,
        _ => return client_error(StatusCode::BAD_REQUEST, "order id must be a positive integer"),
    };
    let q = "SELECT id, product_id, quantity, customer_id, status, created_at \
             FROM orders WHERE id = $1";
    match sqlx::query_as::<_, Order>(q)
        .bind(id)
        .fetch_optional(&st.db)
        .await
    {
        Ok(Some(o)) => (StatusCode::OK, Json(o)).into_response(),
        Ok(None) => client_error(StatusCode::NOT_FOUND, "order not found"),
        Err(e) => server_error("get order", e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::Request;
    use http_body_util::BodyExt;
    use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
    use tower::ServiceExt;

    fn order(product_id: i32, quantity: i32, customer_id: &str) -> CreateOrderRequest {
        CreateOrderRequest {
            product_id,
            quantity,
            customer_id: customer_id.to_string(),
        }
    }

    #[test]
    fn validate_enforces_business_rules() {
        assert_eq!(
            order(0, 1, "c").validate(),
            Some("product_id must be a positive integer")
        );
        assert_eq!(
            order(1, 0, "c").validate(),
            Some("quantity must be a positive integer")
        );
        assert_eq!(order(1, 1, "").validate(), Some("customer_id is required"));
        assert_eq!(
            order(1, 1, &"x".repeat(256)).validate(),
            Some("customer_id must be at most 255 characters")
        );
        assert_eq!(order(1, 2, "c").validate(), None);
    }

    // Lazy pool: never connects unless a query runs, so /healthz needs no DB.
    fn test_state() -> AppState {
        let pool = PgPoolOptions::new().connect_lazy_with(
            PgConnectOptions::new()
                .host("localhost")
                .username("u")
                .password("p")
                .database("d"),
        );
        AppState {
            db: pool,
            ready: Arc::new(AtomicBool::new(false)),
        }
    }

    #[tokio::test]
    async fn healthz_returns_ok() {
        let resp = router(test_state())
            .oneshot(
                Request::builder()
                    .uri("/healthz")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let body = resp.into_body().collect().await.unwrap().to_bytes();
        assert_eq!(&body[..], br#"{"status":"ok"}"#);
    }
}
