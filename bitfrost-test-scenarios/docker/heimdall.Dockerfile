# Build heimdall from a sibling checkout (compose sets the build context to
# HEIMDALL_SRC). heimdall's build.rs embeds the git version, so the context
# must include .git.
FROM rust:1.88-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config libssl-dev git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
# --bins: the scenarios also need register_pool (devnet stake pools).
RUN cargo build --release --locked --bins

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/target/release/heimdall /usr/local/bin/heimdall
COPY --from=build /src/target/release/register_pool /usr/local/bin/register_pool
ENTRYPOINT ["heimdall"]
