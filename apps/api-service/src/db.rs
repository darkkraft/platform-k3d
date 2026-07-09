//! Database handle, schema bootstrap, and health probe.

use std::time::Duration;

use sqlx::postgres::{PgConnectOptions, PgPoolOptions, PgSslMode};
use sqlx::PgPool;

use crate::config::Config;

/// Builds a lazily-connected pool. `connect_lazy_with` never touches the network
/// here, so a not-yet-ready database does not fail process start-up — readiness
/// is established by the background retry loop instead.
pub fn pool(cfg: &Config) -> PgPool {
    let ssl = match cfg.db_sslmode.as_str() {
        "disable" => PgSslMode::Disable,
        "allow" => PgSslMode::Allow,
        "prefer" => PgSslMode::Prefer,
        "verify-ca" => PgSslMode::VerifyCa,
        "verify-full" => PgSslMode::VerifyFull,
        _ => PgSslMode::Require,
    };

    let opts = PgConnectOptions::new()
        .host(&cfg.db_host)
        .port(cfg.db_port)
        .username(&cfg.db_user)
        .password(&cfg.db_password)
        .database(&cfg.db_name)
        .ssl_mode(ssl);

    // Bounded pool so the service cannot exhaust the database's connection slots.
    PgPoolOptions::new()
        .max_connections(10)
        .idle_timeout(Duration::from_secs(300))
        .max_lifetime(Duration::from_secs(1800))
        .connect_lazy_with(opts)
}

pub async fn init_schema(db: &PgPool) -> Result<(), sqlx::Error> {
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS orders (
            id SERIAL PRIMARY KEY,
            product_id INTEGER NOT NULL,
            quantity INTEGER NOT NULL,
            customer_id VARCHAR(255) NOT NULL,
            status VARCHAR(50) NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );",
    )
    .execute(db)
    .await
    .map(|_| ())
}

pub async fn ping(db: &PgPool) -> Result<(), sqlx::Error> {
    sqlx::query("SELECT 1").execute(db).await.map(|_| ())
}
