ARG GO_VERSION=1.26.2

FROM golang:${GO_VERSION}-bookworm AS agent-builder

ARG A3_AGENT_VERSION=0.5.35
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

FROM ruby:3.1-slim

ARG A3_IMAGE_VERSION=0.5.35
ARG GO_TASK_VERSION=3.41.0
ARG BUNDLER_VERSION=2.5.22

# Transitional dependency: the runtime still invokes tools/kanban/cli.py
# through the subprocess kanban adapter until the Ruby-native Kanbalone
# adapter becomes the runtime default.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      bash \
      build-essential \
      ca-certificates \
      curl \
      git \
      jq \
      libsqlite3-dev \
      pkg-config \
      procps \
      python3 \
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

RUN gem install bundler -v "${BUNDLER_VERSION}"

WORKDIR /workspace

COPY Gemfile /tmp/a3-engine/Gemfile
COPY Gemfile.lock /tmp/a3-engine/Gemfile.lock
COPY a2o.gemspec /tmp/a3-engine/a2o.gemspec
COPY lib /tmp/a3-engine/lib
COPY bin /tmp/a3-engine/bin

RUN --mount=type=cache,target=/usr/local/bundle/cache \
    cd /tmp/a3-engine \
    && bundle _${BUNDLER_VERSION}_ install \
    && rm -rf /usr/local/bundle/cache/*.gem

COPY config /tmp/a3-engine/config
COPY tools /tmp/a3-engine/tools
COPY tools /opt/a2o/share/tools
COPY docker/compose /opt/a2o/share/docker/compose
RUN cp /opt/a2o/share/docker/compose/a2o-soloboard.release.yml /opt/a2o/share/docker/compose/a2o-soloboard.yml

COPY --from=agent-builder /opt/a2o/agents /opt/a2o/agents

RUN ln -sf /tmp/a3-engine/bin/a3 /usr/local/bin/a3 \
    && ln -sf /tmp/a3-engine/bin/a3 /usr/local/bin/a2o

ENV A3_ROOT_DIR=/workspace
ENV A2O_ROOT_DIR=/workspace
ENV A3_IMAGE_VERSION=${A3_IMAGE_VERSION}
ENV A2O_IMAGE_VERSION=${A3_IMAGE_VERSION}
ENV A2O_AGENT_PACKAGE_DIR=/opt/a2o/agents
ENV A3_AGENT_PACKAGE_DIR=/opt/a2o/agents
ENV RUBYLIB=/tmp/a3-engine/lib

CMD ["sleep", "infinity"]
