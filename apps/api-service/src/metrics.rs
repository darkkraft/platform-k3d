//! Prometheus RED metrics. Metric names and label sets are part of the contract
//! the Grafana dashboards depend on — do not rename without updating them.

use std::time::Instant;

use axum::extract::{MatchedPath, Request};
use axum::middleware::Next;
use axum::response::Response;
use once_cell::sync::Lazy;
use prometheus::{
    register_histogram_vec, register_int_counter_vec, Encoder, HistogramVec, IntCounterVec,
    TextEncoder,
};

static HTTP_REQUESTS_TOTAL: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "http_requests_total",
        "Total HTTP requests by method, route and status code.",
        &["method", "route", "code"]
    )
    .expect("register http_requests_total")
});

static HTTP_REQUEST_DURATION: Lazy<HistogramVec> = Lazy::new(|| {
    register_histogram_vec!(
        "http_request_duration_seconds",
        "HTTP request latency in seconds by method and route.",
        &["method", "route"]
    )
    .expect("register http_request_duration_seconds")
});

/// Middleware recording RED metrics, labelled by the matched route pattern
/// (low cardinality) rather than the raw path.
pub async fn track_metrics(req: Request, next: Next) -> Response {
    let method = req.method().as_str().to_owned();
    let route = req
        .extensions()
        .get::<MatchedPath>()
        .map(|m| m.as_str().to_owned())
        .unwrap_or_else(|| "unmatched".to_owned());

    let start = Instant::now();
    let resp = next.run(req).await;
    let code = resp.status().as_u16().to_string();

    HTTP_REQUESTS_TOTAL
        .with_label_values(&[&method, &route, &code])
        .inc();
    HTTP_REQUEST_DURATION
        .with_label_values(&[&method, &route])
        .observe(start.elapsed().as_secs_f64());

    resp
}

/// Renders the default registry in the Prometheus text exposition format.
pub fn render() -> String {
    let mut buf = Vec::new();
    let encoder = TextEncoder::new();
    // Encoding to an in-memory buffer with the built-in encoder cannot fail.
    encoder
        .encode(&prometheus::gather(), &mut buf)
        .expect("encode metrics");
    String::from_utf8(buf).expect("metrics are valid utf-8")
}
