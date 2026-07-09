//! Runtime configuration, resolved from the environment.
//!
//! Fail-fast: a missing DB credential is a hard error, never an insecure
//! fallback (there is no "postgres"/"postgres" default).

pub struct Config {
    pub port: u16,
    pub db_host: String,
    pub db_port: u16,
    pub db_name: String,
    pub db_sslmode: String,
    pub db_user: String,
    pub db_password: String,
}

fn getenv(key: &str, fallback: &str) -> String {
    match std::env::var(key) {
        Ok(v) if !v.is_empty() => v,
        _ => fallback.to_string(),
    }
}

impl Config {
    pub fn from_env() -> Result<Self, String> {
        let port: u16 = getenv("PORT", "8080")
            .parse()
            .map_err(|_| "PORT must be a valid TCP port".to_string())?;
        let db_port: u16 = getenv("DB_PORT", "5432")
            .parse()
            .map_err(|_| "DB_PORT must be a valid TCP port".to_string())?;

        let db_user = std::env::var("DB_USER").unwrap_or_default();
        let db_password = std::env::var("DB_PASSWORD").unwrap_or_default();

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

        Ok(Config {
            port,
            db_host: getenv("DB_HOST", "platform-db-rw"),
            db_port,
            db_name: getenv("DB_NAME", "orders"),
            db_sslmode: getenv("DB_SSLMODE", "require"),
            db_user,
            db_password,
        })
    }
}
