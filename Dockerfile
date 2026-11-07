# syntax=docker/dockerfile:1
# check=error=true

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.7
# The Pi Durable sidecar's Node, the version its suite runs on
# (docs/agent.md). Only the node binary reaches the final image; npm is
# used in the build stage alone.
FROM docker.io/library/node:24.20.0-bookworm-slim AS node

FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /rails

# sqlite3 is here for ops/backup, which snapshots the databases inside the web
# container. chromium and its fonts are for an agent's computer: visit_website
# runs headless Chromium in the agent container (docs/agent.md).
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libstdc++6 sqlite3 chromium fonts-liberation && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY --from=node /usr/local/bin/node /usr/local/bin/node

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config libssl-dev && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

COPY . .

# The sidecar's packages, exactly as agent/package-lock.json pins them, with
# no install scripts. .dockerignore keeps any local agent/node_modules out.
COPY --from=node /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
RUN cd agent && node /usr/local/lib/node_modules/npm/bin/npm-cli.js ci --ignore-scripts --omit=dev --no-audit --no-fund && \
    rm -rf ~/.npm

RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile && \
    chmod -R a+rX public/assets

FROM base

RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# The entrypoint migrates when the command is Falcon (bin/docker-entrypoint);
# the job role overrides the command and leaves the database alone.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Falcon on :80 for kamal-proxy.
EXPOSE 80
CMD ["./bin/falcon"]
