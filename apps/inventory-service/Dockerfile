# --- Build stage -------------------------------------------------------------
FROM rust:1.88-bookworm AS builder

WORKDIR /src

# Cache dependency compilation separately from source for faster rebuilds.
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo 'fn main() {}' > src/main.rs \
    && cargo build --release \
    && rm -rf src

COPY . .
# Rebuild the real sources (the stub above primed the dependency cache).
RUN touch src/main.rs && cargo build --release

# --- Final stage: distroless nonroot -----------------------------------------
FROM gcr.io/distroless/cc-debian12:nonroot

# Runs as UID 65532 (nonroot) from the base image; no shell, no package manager.
COPY --from=builder /src/target/release/inventory-service /usr/local/bin/inventory-service

EXPOSE 8081
USER nonroot:nonroot
ENTRYPOINT ["/usr/local/bin/inventory-service"]

LABEL org.opencontainers.image.title="inventory-service" \
      org.opencontainers.image.description="Product-inventory HTTP API" \
      org.opencontainers.image.source="https://github.com/example-org/platform-gitops" \
      org.opencontainers.image.licenses="MIT"
