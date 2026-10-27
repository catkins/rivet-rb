# syntax=docker/dockerfile:1
FROM ruby:3.3-bookworm

# Magnus/rb_sys need Ruby headers (included above), a C compiler, libclang,
# and current stable Rust. Pin the engine separately in compose.yaml.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates clang curl git libclang-dev libssl-dev pkg-config \
    && rm -rf /var/lib/apt/lists/* \
    && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --default-toolchain stable

ENV PATH="/root/.cargo/bin:${PATH}" \
    RB_SYS_CARGO_PROFILE=dev \
    CARGO_BUILD_JOBS=2
WORKDIR /app
COPY . .
# Cache Rust downloads and debug artifacts across source changes. rake copies
# the extension into lib/rivet, outside the cache, so it remains in the image.
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    --mount=type=cache,target=/app/target \
    bundle install && bundle exec rake compile

CMD ["bundle", "exec", "ruby", "examples/server.rb"]
