ARG GO_VERSION=1.26.2

FROM golang:${GO_VERSION}-bookworm AS agent-builder

ARG A3_AGENT_VERSION=0.5.85
ARG A3_AGENT_TARGETS=
ARG PACKAGE_ARCHIVES=1
ARG PUBLICATION_BUNDLE_ARCHIVE=
ARG PUBLICATION_BUNDLE_URL=
ARG PUBLICATION_BUNDLE_SHA256=

WORKDIR /src/agent-go

COPY agent-go/go.mod ./go.mod
COPY agent-go/go.sum ./go.sum
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download
COPY agent-go/cmd ./cmd
COPY agent-go/internal ./internal
COPY agent-go/scripts ./scripts

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    DIST_DIR=/opt/a2o/agents VERSION="${A3_AGENT_VERSION}" TARGETS="${A3_AGENT_TARGETS}" PACKAGE_ARCHIVES="${PACKAGE_ARCHIVES}" PUBLICATION_BUNDLE_ARCHIVE="${PUBLICATION_BUNDLE_ARCHIVE}" PUBLICATION_BUNDLE_URL="${PUBLICATION_BUNDLE_URL}" PUBLICATION_BUNDLE_SHA256="${PUBLICATION_BUNDLE_SHA256}" ./scripts/build-release.sh

FROM ruby:3.1-slim AS ruby-builder

ARG BUNDLER_VERSION=2.5.22

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      libsqlite3-dev \
      pkg-config \
    && rm -rf /var/lib/apt/lists/*

ENV PATH=/usr/local/bin:/usr/local/bundle/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

RUN gem install bundler -v "${BUNDLER_VERSION}"

WORKDIR /workspace

COPY Gemfile /tmp/a3-engine/Gemfile
COPY Gemfile.lock /tmp/a3-engine/Gemfile.lock
COPY a2o.gemspec /tmp/a3-engine/a2o.gemspec
COPY lib /tmp/a3-engine/lib
COPY bin /tmp/a3-engine/bin

RUN --mount=type=cache,target=/usr/local/bundle/cache \
    cd /tmp/a3-engine \
    && BUNDLE_WITHOUT=development:test bundle _${BUNDLER_VERSION}_ install \
    && rm -rf /usr/local/bundle/cache/*.gem

FROM ruby:3.1-slim

ARG A3_IMAGE_VERSION=0.5.85
ARG GO_TASK_VERSION=3.41.0
ARG BUNDLER_VERSION=2.5.22

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      git \
      jq \
      libsqlite3-0 \
      procps \
      ripgrep \
    && rm -rf /var/lib/apt/lists/*

ENV PATH=/usr/local/bin:/usr/local/bundle/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

RUN arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
      amd64) task_arch="amd64" ;; \
      arm64) task_arch="arm64" ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/go-task/task/releases/download/v${GO_TASK_VERSION}/task_linux_${task_arch}.tar.gz" \
      | tar -xz -C /usr/local/bin task \
    && chmod +x /usr/local/bin/task

WORKDIR /workspace

COPY --from=ruby-builder /usr/local/bundle /usr/local/bundle
COPY --from=ruby-builder /tmp/a3-engine/Gemfile /tmp/a3-engine/Gemfile
COPY --from=ruby-builder /tmp/a3-engine/Gemfile.lock /tmp/a3-engine/Gemfile.lock
COPY --from=ruby-builder /tmp/a3-engine/a2o.gemspec /tmp/a3-engine/a2o.gemspec
COPY --from=ruby-builder /tmp/a3-engine/lib /tmp/a3-engine/lib
COPY --from=ruby-builder /tmp/a3-engine/bin /tmp/a3-engine/bin

COPY config /tmp/a3-engine/config
COPY tools/reference_validation /tmp/a3-engine/tools/reference_validation
COPY tools/reference_validation /opt/a2o/share/tools/reference_validation
COPY docker/compose /opt/a2o/share/docker/compose
RUN cp /opt/a2o/share/docker/compose/a2o-kanbalone.release.yml /opt/a2o/share/docker/compose/a2o-kanbalone.yml

COPY --from=agent-builder /opt/a2o/agents /opt/a2o/agents

RUN arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
      amd64) a2o_arch="amd64" ;; \
      arm64) a2o_arch="arm64" ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac \
    && find /opt/a2o/agents -mindepth 1 -maxdepth 1 -type d ! -name "linux-${a2o_arch}" -exec rm -rf {} + \
    && find /opt/a2o/agents -mindepth 1 -maxdepth 1 -type f -name 'a2o-agent-[0-9]*-*.tar.gz' -delete \
    && ln -sf "/opt/a2o/agents/linux-${a2o_arch}/a2o" /usr/local/bin/a2o-host \
    && ln -sf /tmp/a3-engine/bin/a3 /usr/local/bin/a2o \
    && printf '%s\n' \
      '#!/usr/bin/env sh' \
      'if [ "$1" = "agent" ] && [ "$2" = "package" ]; then' \
      '  echo "removed A3 runtime package command: a3 agent package; migration_required=true replacement_command=\"a2o agent package\"" >&2' \
      '  exit 2' \
      'fi' \
      'exec /tmp/a3-engine/bin/a3 "$@"' \
      > /usr/local/bin/a3 \
    && chmod 0755 /usr/local/bin/a3

ENV A2O_ROOT_DIR=/workspace
ENV A3_IMAGE_VERSION=${A3_IMAGE_VERSION}
ENV A2O_IMAGE_VERSION=${A3_IMAGE_VERSION}
ENV A2O_AGENT_PACKAGE_DIR=/opt/a2o/agents
ENV RUBYLIB=/tmp/a3-engine/lib

CMD ["sleep", "infinity"]
