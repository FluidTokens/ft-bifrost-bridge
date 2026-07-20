# Build heimdall from a sibling checkout (compose sets the build context to
# HEIMDALL_SRC). heimdall's build.rs embeds the git version, so the context
# must include .git.
FROM rust:1.88-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config libssl-dev git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN cargo build --release --locked --bin heimdall

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/target/release/heimdall /usr/local/bin/heimdall
ENTRYPOINT ["heimdall"]
