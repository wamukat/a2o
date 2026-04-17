ARG GO_VERSION=1.26.2

FROM golang:${GO_VERSION}-bookworm AS agent-builder

ARG A3_AGENT_VERSION=dev

WORKDIR /src/agent-go

COPY agent-go/go.mod ./go.mod
COPY agent-go/cmd ./cmd
COPY agent-go/internal ./internal
COPY agent-go/scripts ./scripts

RUN DIST_DIR=/opt/a3/agents VERSION="${A3_AGENT_VERSION}" ./scripts/build-release.sh

FROM ruby:3.1-slim

ARG GO_TASK_VERSION=3.41.0
ARG BUNDLER_VERSION=2.5.22

# Transitional dependency: the runtime still invokes tools/kanban/cli.py
# through the subprocess kanban adapter until the Ruby-native SoloBoard
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
      python3-venv \
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
COPY a3.gemspec /tmp/a3-engine/a3.gemspec
COPY lib /tmp/a3-engine/lib
COPY bin /tmp/a3-engine/bin
COPY tools /tmp/a3-engine/tools
COPY tools /opt/a3/share/tools
COPY docker/compose /opt/a3/share/docker/compose
RUN cp /opt/a3/share/docker/compose/a3-portal-soloboard.release.yml /opt/a3/share/docker/compose/a3-portal-soloboard.yml

RUN cd /tmp/a3-engine \
    && bundle _${BUNDLER_VERSION}_ install \
    && rm -rf /usr/local/bundle/cache/*.gem

COPY --from=agent-builder /opt/a3/agents /opt/a3/agents

RUN ln -sf /tmp/a3-engine/bin/a3 /usr/local/bin/a3 \
    && ln -sf /tmp/a3-engine/bin/a3 /usr/local/bin/a2o

ENV A3_ROOT_DIR=/workspace
ENV A3_AGENT_PACKAGE_DIR=/opt/a3/agents
ENV RUBYLIB=/tmp/a3-engine/lib

CMD ["sleep", "infinity"]
