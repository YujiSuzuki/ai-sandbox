#!/bin/bash
# check-gvisor.sh
# Read-only check of whether gVisor (runsc) is usable as a Docker runtime on
# the host OS. Makes no changes -- reports current status and next steps.
#
# Usage:
#   ./check-gvisor.sh
#
# Examples:
#   ./check-gvisor.sh
# ---
# ホストOS上でgVisor(runsc)をDockerランタイムとして使える状態か確認する、
# 読み取り専用の診断スクリプト。設定変更は一切行わない。

set -uo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

header() { echo -e "${BLUE}=== $* ===${NC}"; }
ok()     { echo -e "${GREEN}[OK]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()   { echo -e "${RED}[NG]${NC} $*"; }

header "Host OS"
OS="$(uname -s)"
ARCH="$(uname -m)"
echo "  OS: $OS ($ARCH)"

header "Docker"
if ! command -v docker >/dev/null 2>&1; then
    fail "docker command not found on host"
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    fail "docker daemon not reachable (is Docker Desktop / Docker Engine running?)"
    exit 1
fi
ok "docker daemon is reachable"
echo "  Context: $(docker context show 2>/dev/null || echo unknown)"

header "Registered Docker runtimes"
RUNTIMES="$(docker info --format '{{json .Runtimes}}' 2>/dev/null || echo '{}')"
echo "  $RUNTIMES"

if echo "$RUNTIMES" | grep -q '"runsc"'; then
    ok "runsc is already registered as a Docker runtime"
    echo "  Try: docker run --rm --runtime=runsc hello-world"
else
    warn "runsc is not registered as a Docker runtime yet"
fi

header "runsc binary on host PATH"
if command -v runsc >/dev/null 2>&1; then
    ok "found: $(command -v runsc)"
    runsc --version 2>&1 | head -1 | sed 's/^/  /'
else
    warn "runsc binary not found on host PATH"
fi

header "Guidance"
DOCKER_CONTEXT="$(docker context show 2>/dev/null || echo unknown)"
case "$OS" in
    Linux)
        echo "  Native Linux + Docker Engine: without an extra runtime, a kernel exploit"
        echo "  inside a container reaches the host kernel directly (see docs/comparison.md)."
        echo "  Worth considering: install runsc and register it in /etc/docker/daemon.json's"
        echo "  \"runtimes\" key, then restart dockerd. See"
        echo "  https://gvisor.dev/docs/user_guide/install/ and"
        echo "  https://gvisor.dev/docs/user_guide/docker/."
        ;;
    Darwin)
        echo "  On macOS, Docker already runs inside a lightweight Linux VM (Docker"
        echo "  Desktop / OrbStack / etc.), regardless of container runtime. A kernel"
        echo "  exploit inside a container is contained by that VM boundary already,"
        echo "  so gVisor is generally not necessary here -- see docs/comparison.md."
        case "$DOCKER_CONTEXT" in
            orbstack)
                warn "Docker context is 'orbstack': gVisor's runsc is currently known"
                echo "  to fail on OrbStack. OrbStack's VM has /tmp symlinked to"
                echo "  /private/tmp, and runsc's chroot safety check rejects that,"
                echo "  crashing the sandbox on startup. See current status at"
                echo "  https://github.com/orbstack/orbstack/issues/2362 before"
                echo "  attempting this."
                ;;
            *)
                echo "  Docker context: '$DOCKER_CONTEXT'."
                ;;
        esac
        ;;
    *)
        warn "Unrecognized OS ($OS); no specific guidance available."
        ;;
esac
