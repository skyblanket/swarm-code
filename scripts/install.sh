#!/bin/sh
# swarm-code — universal installer
#
# Usage:   curl -fsSL https://raw.githubusercontent.com/skyblanket/swarm-code/main/scripts/install.sh | sh
# Or:      curl -fsSL .../install.sh | sh -s -- --bindir /custom/path
#
# Detects OS/arch, pulls the matching binary from the latest GitHub release,
# installs `swarm` to ~/.local/bin (override with --bindir or $SWARM_BINDIR),
# and seeds ~/.swarm-code/settings.json if it doesn't already exist.
#
# POSIX-shell only — runs under /bin/sh on every Linux distro and on macOS.
# No bash-isms, no dependencies beyond curl/wget + tar/uname.

set -eu

REPO="skyblanket/swarm-code"
BINDIR="${SWARM_BINDIR:-$HOME/.local/bin}"
CFGDIR="$HOME/.swarm-code"
TAG=""

# ----- pretty output ---------------------------------------------------------
if [ -t 1 ]; then
    BOLD="$(printf '\033[1m')"
    DIM="$(printf '\033[2m')"
    GREEN="$(printf '\033[32m')"
    RED="$(printf '\033[31m')"
    YELLOW="$(printf '\033[33m')"
    RESET="$(printf '\033[0m')"
else
    BOLD=""; DIM=""; GREEN=""; RED=""; YELLOW=""; RESET=""
fi
info()  { printf '%s\n' "${GREEN}$*${RESET}"; }
note()  { printf '%s\n' "${DIM}$*${RESET}"; }
warn()  { printf '%s\n' "${YELLOW}$*${RESET}" >&2; }
die()   { printf '%s\n' "${RED}error:${RESET} $*" >&2; exit 1; }

# ----- args ------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --bindir) BINDIR="$2"; shift 2 ;;
        --tag)    TAG="$2"; shift 2 ;;
        --help|-h)
            cat <<EOF
swarm-code installer

  --bindir DIR    Install binary here (default: ~/.local/bin)
  --tag    TAG    Pin a specific release tag (default: latest)
  --help          Show this help

Environment: SWARM_BINDIR overrides --bindir.
EOF
            exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

# ----- platform detect ------------------------------------------------------
detect_platform() {
    os=$(uname -s 2>/dev/null || echo "")
    arch=$(uname -m 2>/dev/null || echo "")

    case "$os" in
        Darwin)                 os_tag="darwin" ;;
        Linux)                  os_tag="linux"  ;;
        # WSL identifies as Linux already; explicit MINGW/CYGWIN catch is
        # for users who somehow run this from a native Windows shell.
        MINGW*|MSYS*|CYGWIN*)
            cat <<EOF
${RED}Native Windows is not supported.${RESET}

Like Claude Code, swarm-code's Windows path is WSL2:

  ${BOLD}wsl --install${RESET}      # in admin PowerShell, then reboot
  ${BOLD}wsl${RESET}                 # drop into Ubuntu
  curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | sh
EOF
            exit 1 ;;
        *) die "unsupported OS: $os" ;;
    esac

    case "$arch" in
        x86_64|amd64)   arch_tag="x86_64" ;;
        arm64|aarch64)  arch_tag="arm64"  ;;
        *)              die "unsupported architecture: $arch" ;;
    esac

    # Intel Mac binaries aren't prebuilt — Apple Silicon dominates and
    # the GitHub Intel runner queue is unusable. Point the user at the
    # build-from-source path so they're not stuck.
    if [ "$os_tag" = "darwin" ] && [ "$arch_tag" = "x86_64" ]; then
        cat <<EOF
${RED}No prebuilt binary for Intel Mac yet.${RESET}

Build from source instead (~30s, needs Xcode CLT + brew):

  ${BOLD}git clone https://github.com/skyblanket/swarmrt   ../swarmrt${RESET}
  ${BOLD}git clone https://github.com/$REPO${RESET}
  cd ../swarmrt   && make swc libswarmrt
  cd ../swarm-code && make
  cp bin/swarm-code "$BINDIR/swarm"
EOF
        exit 1
    fi

    printf '%s-%s\n' "$os_tag" "$arch_tag"
}

# ----- downloader (curl or wget) --------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

fetch() {
    url="$1"; out="$2"
    if have curl; then
        curl -fsSL -o "$out" "$url"
    elif have wget; then
        wget -qO "$out" "$url"
    else
        die "need curl or wget"
    fi
}

fetch_stdout() {
    url="$1"
    if have curl; then
        curl -fsSL "$url"
    elif have wget; then
        wget -qO- "$url"
    else
        die "need curl or wget"
    fi
}

# ----- find latest release tag ----------------------------------------------
latest_tag() {
    # Resolve via GitHub API.
    fetch_stdout "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p' \
        | head -n1
}

# ----- main ------------------------------------------------------------------
echo ""
echo "${BOLD}swarm-code installer${RESET}"
echo "─────────────────────"

platform=$(detect_platform)
note "platform: $platform"

if [ -z "$TAG" ]; then
    TAG=$(latest_tag || true)
    [ -z "$TAG" ] && die "no releases found at github.com/$REPO/releases — pass --tag VX.Y.Z"
fi
note "release:  $TAG"

asset="swarm-$platform"
url="https://github.com/$REPO/releases/download/$TAG/$asset"
note "asset:    $url"

mkdir -p "$BINDIR"
tmp=$(mktemp -t swarm-install.XXXXXX)
trap 'rm -f "$tmp"' EXIT INT TERM

echo ""
echo "Downloading…"
fetch "$url" "$tmp" || die "download failed — check $url is reachable"
chmod +x "$tmp"

# Sanity check — bail before clobbering anything if the file looks wrong.
if [ ! -s "$tmp" ]; then
    die "downloaded file is empty"
fi

mv "$tmp" "$BINDIR/swarm"
trap - EXIT
info "installed: $BINDIR/swarm"

# ----- seed config -----------------------------------------------------------
mkdir -p "$CFGDIR/sessions"
if [ ! -f "$CFGDIR/settings.json" ]; then
    cat > "$CFGDIR/settings.json" <<'JSON'
{
  "endpoint": "https://api.moonshot.ai/v1/chat/completions",
  "model":    "kimi-k2.6",
  "api_key":  "",
  "permissions": {
    "bash":  "allow",
    "read":  "allow",
    "write": "allow",
    "edit":  "allow",
    "web":   "allow"
  }
}
JSON
    note "wrote default config: $CFGDIR/settings.json"
    warn "→ open it and set \"api_key\" before running \`swarm\`"
fi

# ----- PATH check ------------------------------------------------------------
case ":$PATH:" in
    *":$BINDIR:"*) ;;
    *)
        echo ""
        warn "$BINDIR is not on your PATH"
        case "${SHELL:-}" in
            */zsh)
                echo "  echo 'export PATH=\"$BINDIR:\$PATH\"' >> ~/.zshrc && source ~/.zshrc" ;;
            */bash)
                echo "  echo 'export PATH=\"$BINDIR:\$PATH\"' >> ~/.bashrc && source ~/.bashrc" ;;
            *)
                echo "  add this to your shell rc:  export PATH=\"$BINDIR:\$PATH\"" ;;
        esac
        ;;
esac

echo ""
info "done. run:  ${BOLD}swarm${RESET}"
