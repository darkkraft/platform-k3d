use crate::config::Config;
use sqlx::postgres::{PgConnectOptions, PgPool, PgPoolOptions, PgSslMode};
use std::time::Duration;

/// The schema this service owns. Applied idempotently at startup.
pub const SCHEMA: &str = "CREATE TABLE IF NOT EXISTS products (\
    id SERIAL PRIMARY KEY, \
    name VARCHAR(255) NOT NULL, \
    quantity INTEGER NOT NULL DEFAULT 0 CHECK (quantity >= 0), \
    price DECIMAL(10,2) NOT NULL CHECK (price >= 0));";

/// Builds a lazily-connected pool so a not-yet-ready database never blocks
/// startup; the readiness probe gates traffic until the schema is applied.
pub fn make_pool(cfg: &Config) -> Result<PgPool, String> {
    let ssl = match cfg.db_sslmode.as_str() {
        "disable" => PgSslMode::Disable,
        "allow" => PgSslMode::Allow,
        "prefer" => PgSslMode::Prefer,
        "require" => PgSslMode::Require,
        "verify-ca" => PgSslMode::VerifyCa,
        "verify-full" => PgSslMode::VerifyFull,
        other => return Err(format!("invalid DB_SSLMODE: {other}")),
    };
    let port: u16 = cfg
        .db_port
        .parse()
        .map_err(|_| format!("invalid DB_PORT: {}", cfg.db_port))?;

    let opts = PgConnectOptions::new()
        .host(&cfg.db_host)
        .port(port)
        .username(&cfg.db_user)
        .password(&cfg.db_password)
        .database(&cfg.db_name)
        .ssl_mode(ssl);

    // Bounded pool so the service cannot exhaust the database's connection slots.
    let pool = PgPoolOptions::new()
        .max_connections(10)
        .idle_timeout(Duration::from_secs(300))
        .max_lifetime(Duration::from_secs(1800))
        .connect_lazy_with(opts);

    Ok(pool)
}
