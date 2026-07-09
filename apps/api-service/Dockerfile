# --- Build stage -------------------------------------------------------------
FROM rust:1.88-bookworm AS builder

WORKDIR /src

# Compile dependencies against a stub main first so they cache separately from
# the application sources (faster incremental rebuilds).
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo 'fn main() {}' > src/main.rs && \
    cargo build --release && \
    rm -rf src

COPY . .
# Ensure cargo recompiles with the real sources (the stub above is newer).
RUN touch src/main.rs && cargo build --release

# --- Final stage: distroless nonroot (glibc, no shell, no package manager) ---
FROM gcr.io/distroless/cc-debian12:nonroot

COPY --from=builder /src/target/release/api-service /usr/local/bin/api-service

EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/usr/local/bin/api-service"]

LABEL org.opencontainers.image.title="api-service" \
      org.opencontainers.image.description="Order-management HTTP API" \
      org.opencontainers.image.source="https://github.com/example-org/platform-gitops" \
      org.opencontainers.image.licenses="MIT"
