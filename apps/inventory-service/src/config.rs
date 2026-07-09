use std::env;

/// Fully-resolved runtime configuration, read from the environment.
pub struct Config {
    pub port: String,
    pub db_host: String,
    pub db_port: String,
    pub db_user: String,
    pub db_password: String,
    pub db_name: String,
    pub db_sslmode: String,
}

impl Config {
    /// Reads configuration from the environment and fails if required secrets
    /// are absent. There are NO insecure fallback defaults for credentials — a
    /// missing password is a hard error, not "postgres".
    pub fn from_env() -> Result<Self, String> {
        let db_user = env::var("DB_USER").unwrap_or_default();
        let db_password = env::var("DB_PASSWORD").unwrap_or_default();

        let mut missing = Vec::new();
        if db_user.is_empty() {
            missing.push("DB_USER");
        }
        if db_password.is_empty() {
            missing.push("DB_PASSWORD");
        }
        if !missing.is_empty() {
            return Err(format!(
                "required environment variables not set: {}",
                missing.join(", ")
            ));
        }

        Ok(Self {
            port: getenv("PORT", "8081"),
            db_host: getenv("DB_HOST", "platform-db-rw"),
            db_port: getenv("DB_PORT", "5432"),
            db_name: getenv("DB_NAME", "inventory"),
            db_sslmode: getenv("DB_SSLMODE", "require"),
            db_user,
            db_password,
        })
    }
}

fn getenv(key: &str, fallback: &str) -> String {
    match env::var(key) {
        Ok(v) if !v.is_empty() => v,
        _ => fallback.to_string(),
    }
}
