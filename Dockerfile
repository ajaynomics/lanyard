# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# check=error=true

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version. Each base
# image is pinned by digest as well as tag, so a rebuild gets the same bytes;
# change a digest with its tag.
ARG RUBY_VERSION=4.0.7
# The Pi Durable sidecar's Node, the version its suite runs on
# (docs/agent.md). Only the node binary reaches the final image; npm is
# used in the build stage alone.
FROM docker.io/library/node:24.20.0-bookworm-slim@sha256:ba849c60be29959425b8734d57b8b4b7d56f98edd9504c9af091d5281095a71e AS node

FROM docker.io/library/ruby:$RUBY_VERSION-slim@sha256:6c6b7b8c7d750604178aa60c2fa436890cd17c5695bdbd3213db2e4efbf98eb9 AS base

WORKDIR /rails

# sqlite3 is here for ops/backup, which snapshots the databases inside the web
# container. chromium and its fonts are for an agent's computer: visit_website
# runs headless Chromium in the agent container (docs/agent.md).
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libstdc++6 sqlite3 chromium fonts-liberation openssh-client && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY --from=node /usr/local/bin/node /usr/local/bin/node

# The password manager's command-line client, for saved sign-ins
# (lib/durable_assistants/passbolt.rb, docs/passwords.md). Pinned by checksum.
ARG PASSBOLT_CLI_VERSION=0.5.3
RUN arch=$(dpkg --print-architecture) && \
    case "$arch" in \
      amd64) sum=ebe14f4413e8811669437bd083a345a0aa234be4a8c89af3bbade400cd93a0dd ;; \
      arm64) sum=0d3b3eb323e0f92b25d4c6ea65483a92c1c9fdd3cd007c9d368a4dfbd2502a98 ;; \
      *) echo "no passbolt CLI for $arch" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/passbolt.deb "https://github.com/passbolt/go-passbolt-cli/releases/download/v${PASSBOLT_CLI_VERSION}/go-passbolt-cli_${PASSBOLT_CLI_VERSION}_linux_${arch}.deb" && \
    echo "$sum  /tmp/passbolt.deb" | sha256sum -c - && \
    dpkg -i /tmp/passbolt.deb && rm /tmp/passbolt.deb

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
# no install scripts, then agent/patches.mjs's fixes, which fail the build if
# a package's code has moved. .dockerignore keeps any local agent/node_modules out.
COPY --from=node /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
RUN cd agent && node /usr/local/lib/node_modules/npm/bin/npm-cli.js ci --ignore-scripts --omit=dev --no-audit --no-fund && \
    node patches.mjs && \
    rm -rf ~/.npm

RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY.
# The dummy secret it writes to tmp/local_secret.txt stays out of the image.
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile && \
    chmod -R a+rX public/assets && \
    rm -f tmp/local_secret.txt

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
