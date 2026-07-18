FROM node:20-slim

# Install required tools
# 必要なツールをインストール
RUN apt-get update && apt-get install -y \
    ca-certificates \
    git \
    python3 \
    python3-pip \
    vim \
    less \
    sudo \
    curl \
    wget \
    iputils-ping \
    dnsutils \
    jq \
    # Process utilities (ps, top, kill commands) / プロセス管理ツール (ps, top, kill コマンド)
    procps \
    # Advanced network debugging tools (uncomment if needed):
    # ネットワーク詳細デバッグツール（必要に応じてコメント解除）:
    # netcat-openbsd \   # Port connectivity testing / ポート到達性テスト
    # iproute2 \         # Modern network tools (ip, ss commands) / モダンなネットワークツール (ip, ss コマンド)
    && rm -rf /var/lib/apt/lists/*

# Install Go (for SandboxMCP and other Go tools)
# Go をインストール（SandboxMCP と他の Go ツール用）
ARG GO_VERSION=1.24.12
ARG TARGETARCH
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" | tar -C /usr/local -xz
ENV GOPATH="/home/node/go"
ENV PATH="/usr/local/go/bin:${GOPATH}/bin:${PATH}"

# Install yq (mikefarah/yq, the Go-based YAML processor most tooling means by
# "yq"). Required by .sandbox/scripts/setup-hostmcp.sh's detect_hostmcp_port(),
# which reads server.port from hostmcp.yaml to compute the default HostMCP URL
# — do not remove without checking that call site (it has an awk-based
# fallback, but yq is the primary, more robust path). Debian's apt package
# "yq" is a different, unrelated Python/jq wrapper (kislyuk/yq) with an
# incompatible CLI, so this installs the pinned upstream binary directly
# instead, downloading it straight to its final path (no archive to extract,
# unlike the tarball-based Go install above).
# yq（mikefarah/yq、一般的に「yq」と呼ばれるGo版のYAMLプロセッサ）をインストール。
# .sandbox/scripts/setup-hostmcp.sh の detect_hostmcp_port() が、HostMCPの
# デフォルトURLを求めるためhostmcp.yamlのserver.portを読み取るのに使用する。
# 削除する場合は呼び出し箇所を必ず確認すること（awkベースのフォールバックは
# あるが、yqがより堅牢な主経路）。Debianのaptパッケージ「yq」は別物の
# Python/jqラッパー（kislyuk/yq）でCLIの互換性がないため、ピン留めした本家
# バイナリを直接取得する。上のGoのtar展開とは異なり、バイナリを最終パスに
# そのままダウンロードするだけ。
ARG YQ_VERSION=v4.53.3
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH}" \
    -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

# Install Claude Code
# Claude Code インストール
RUN npm install -g @anthropic-ai/claude-code

# Install Gemini CLI
# Gemini CLI インストール
RUN npm install -g @google/gemini-cli

# Configure sudoers (allow only package managers)
# ⚠️ SECURITY: npm/pip3 sudo can be exploited via malicious packages.
#    See README.md "Security Features" for mitigation options.
# sudoers設定 ⚠️ npm/pip3のsudoは悪意あるパッケージで悪用される可能性あり（詳細はREADME参照）
RUN echo "node ALL=(ALL) NOPASSWD: /usr/bin/apt-get" > /etc/sudoers.d/node && \
    echo "node ALL=(ALL) NOPASSWD: /usr/bin/apt" >> /etc/sudoers.d/node && \
    echo "node ALL=(ALL) NOPASSWD: /usr/bin/dpkg" >> /etc/sudoers.d/node && \
    echo "node ALL=(ALL) NOPASSWD: /usr/bin/pip3" >> /etc/sudoers.d/node && \
    echo "node ALL=(ALL) NOPASSWD: /usr/local/bin/npm" >> /etc/sudoers.d/node && \
    chmod 0440 /etc/sudoers.d/node

# Prepare node user home directory
# node ユーザーのホームディレクトリ準備
RUN mkdir -p /home/node/.claude /home/node/.local/bin \
    && chown -R node:node /home/node

# Switch to node user
# node ユーザーに切り替え
USER node

# Add .local/bin to PATH for persistent tool installations
# 永続化されたツールインストール用に.local/binをPATHに追加
ENV PATH="/home/node/.local/bin:${PATH}"

WORKDIR /workspace
CMD ["bash"]
