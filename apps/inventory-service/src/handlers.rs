use crate::AppState;
use axum::{
    body::Bytes,
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sqlx::Row;
use std::sync::atomic::Ordering;
use std::time::Duration;

#[derive(Serialize)]
pub struct Product {
    pub id: i32,
    pub name: String,
    pub quantity: i32,
    pub price: f64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UpdateInventoryRequest {
    pub quantity: i32,
}

impl UpdateInventoryRequest {
    /// Enforces business rules; returns a client-safe message on failure.
    /// Negative inventory is rejected — the original service allowed it.
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.quantity < 0 {
            return Err("quantity must be zero or a positive integer");
        }
        Ok(())
    }
}

const LIST_SQL: &str = "SELECT id, name, quantity, price::float8 AS price FROM products";

/// Liveness: the process is up and serving.
pub async fn healthz() -> impl IntoResponse {
    (StatusCode::OK, Json(json!({"status": "ok"})))
}

/// Readiness: schema applied and the database reachable.
pub async fn readyz(State(app): State<AppState>) -> Response {
    if !app.ready.load(Ordering::Relaxed) {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"status": "initialising"})),
        )
            .into_response();
    }
    let ping = tokio::time::timeout(
        Duration::from_secs(2),
        sqlx::query("SELECT 1").execute(&app.pool),
    )
    .await;
    match ping {
        Ok(Ok(_)) => (StatusCode::OK, Json(json!({"status": "ready"}))).into_response(),
        _ => {
            tracing::warn!("readiness check failed");
            (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({"status": "db unavailable"})),
            )
                .into_response()
        }
    }
}

pub async fn metrics() -> impl IntoResponse {
    crate::metrics::render()
}

pub async fn list_products(State(app): State<AppState>) -> Response {
    let sql = format!("{LIST_SQL} ORDER BY id LIMIT 100");
    match sqlx::query(&sql).fetch_all(&app.pool).await {
        Ok(rows) => {
            let products: Vec<Product> = rows.iter().map(row_to_product).collect();
            (StatusCode::OK, Json(products)).into_response()
        }
        Err(e) => server_error("list products", e),
    }
}

pub async fn get_product(State(app): State<AppState>, Path(id): Path<String>) -> Response {
    let id = match parse_id(&id) {
        Some(id) => id,
        None => return bad_request("product id must be a positive integer"),
    };
    let sql = format!("{LIST_SQL} WHERE id = $1");
    match sqlx::query(&sql).bind(id).fetch_optional(&app.pool).await {
        Ok(Some(row)) => (StatusCode::OK, Json(row_to_product(&row))).into_response(),
        Ok(None) => not_found("product not found"),
        Err(e) => server_error("get product", e),
    }
}

pub async fn update_inventory(
    State(app): State<AppState>,
    Path(id): Path<String>,
    body: Bytes,
) -> Response {
    let id = match parse_id(&id) {
        Some(id) => id,
        None => return bad_request("product id must be a positive integer"),
    };
    let req: UpdateInventoryRequest = match serde_json::from_slice(&body) {
        Ok(r) => r,
        Err(_) => return bad_request("invalid JSON body"),
    };
    if let Err(msg) = req.validate() {
        return bad_request(msg);
    }
    match sqlx::query("UPDATE products SET quantity = $1 WHERE id = $2")
        .bind(req.quantity)
        .bind(id)
        .execute(&app.pool)
        .await
    {
        // A successful UPDATE that touched no rows means the product does not exist.
        Ok(res) if res.rows_affected() == 0 => not_found("product not found"),
        Ok(_) => (StatusCode::OK, Json(json!({"status": "updated"}))).into_response(),
        Err(e) => server_error("update inventory", e),
    }
}

fn row_to_product(row: &sqlx::postgres::PgRow) -> Product {
    Product {
        id: row.get("id"),
        name: row.get("name"),
        quantity: row.get("quantity"),
        price: row.get("price"),
    }
}

/// Positive-integer path id, or None for a client error.
fn parse_id(raw: &str) -> Option<i32> {
    match raw.parse::<i32>() {
        Ok(n) if n > 0 => Some(n),
        _ => None,
    }
}

fn bad_request(msg: &str) -> Response {
    (StatusCode::BAD_REQUEST, Json(json!({ "error": msg }))).into_response()
}

fn not_found(msg: &str) -> Response {
    (StatusCode::NOT_FOUND, Json(json!({ "error": msg }))).into_response()
}

/// Logs the real error and returns a generic message — never leak internal
/// details (SQL, driver errors) to clients.
fn server_error(op: &str, err: sqlx::Error) -> Response {
    tracing::error!(op = op, error = %err, "request failed");
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(json!({"error": "internal server error"})),
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{body::Body, http::Request, routing::get, Router};
    use tower::ServiceExt;

    #[test]
    fn validate_rejects_negative() {
        assert_eq!(
            UpdateInventoryRequest { quantity: -1 }.validate(),
            Err("quantity must be zero or a positive integer")
        );
    }

    #[test]
    fn validate_accepts_zero_and_positive() {
        assert!(UpdateInventoryRequest { quantity: 0 }.validate().is_ok());
        assert!(UpdateInventoryRequest { quantity: 7 }.validate().is_ok());
    }

    #[tokio::test]
    async fn healthz_returns_ok() {
        let app = Router::new().route("/healthz", get(healthz));
        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/healthz")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        assert_eq!(&bytes[..], br#"{"status":"ok"}"#);
    }
}
