use once_cell::sync::Lazy;
use prometheus::{
    register_counter_vec, register_histogram_vec, CounterVec, Encoder, HistogramVec, TextEncoder,
};

/// RED metrics. Names/labels are a contract with the Grafana dashboards.
pub static HTTP_REQUESTS_TOTAL: Lazy<CounterVec> = Lazy::new(|| {
    register_counter_vec!(
        "http_requests_total",
        "Total HTTP requests by method, route and status code.",
        &["method", "route", "code"]
    )
    .expect("register http_requests_total")
});

pub static HTTP_REQUEST_DURATION: Lazy<HistogramVec> = Lazy::new(|| {
    register_histogram_vec!(
        "http_request_duration_seconds",
        "HTTP request latency in seconds by method and route.",
        &["method", "route"]
    )
    .expect("register http_request_duration_seconds")
});

/// Forces registration so `/metrics` reports the series even before first use.
pub fn init() {
    Lazy::force(&HTTP_REQUESTS_TOTAL);
    Lazy::force(&HTTP_REQUEST_DURATION);
}

/// Renders the default registry in the Prometheus text exposition format.
pub fn render() -> String {
    let mut buf = Vec::new();
    let encoder = TextEncoder::new();
    let families = prometheus::gather();
    encoder
        .encode(&families, &mut buf)
        .expect("encode metrics");
    String::from_utf8(buf).unwrap_or_default()
}
