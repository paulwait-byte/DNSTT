#!/usr/bin/env bash
#
# install-server.sh — set up a DNS-over-Tunnel (dnstt) server on a VPS.
#
# Usage:
#   sudo bash install-server.sh <tunnel-domain> [ssh-user]
#
# Example:
#   sudo bash install-server.sh t.example.com vpn
#
# What it does:
#   1. Installs build deps + Go (if missing) and an SSH server.
#   2. Clones and builds dnstt-server.
#   3. Generates a server keypair (prints the public key).
#   4. Creates a dedicated SSH user for the VPN.
#   5. Installs and starts a systemd service that listens on UDP/53 and
#      forwards the tunneled stream to the local SSH server (127.0.0.1:22).
#
set -euo pipefail

TUNNEL_DOMAIN="${1:-}"
SSH_USER="${2:-vpn}"
DNSTT_REPO="https://www.bamsoftware.com/git/dnstt.git"
PREFIX="/opt/dnstt"
GO_VERSION="1.22.5"

if [[ -z "$TUNNEL_DOMAIN" ]]; then
  echo "ERROR: tunnel domain required." >&2
  echo "Usage: sudo bash install-server.sh <tunnel-domain> [ssh-user]" >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: please run as root (sudo)." >&2
  exit 1
fi

echo "==> Tunnel domain : $TUNNEL_DOMAIN"
echo "==> SSH VPN user  : $SSH_USER"
echo

# ---------------------------------------------------------------------------
# 1. Dependencies
# ---------------------------------------------------------------------------
echo "==> Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y git curl ca-certificates openssh-server iptables

# Install Go if not present or too old.
if ! command -v go >/dev/null 2>&1; then
  echo "==> Installing Go ${GO_VERSION}..."
  ARCH="$(dpkg --print-architecture)"
  case "$ARCH" in
    amd64) GO_ARCH="amd64" ;;
    arm64) GO_ARCH="arm64" ;;
    *)     GO_ARCH="$ARCH" ;;
  esac
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o /tmp/go.tgz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tgz
  rm -f /tmp/go.tgz
fi
export PATH="$PATH:/usr/local/go/bin"

# ---------------------------------------------------------------------------
# 2. Build dnstt-server
# ---------------------------------------------------------------------------
echo "==> Building dnstt-server..."
mkdir -p "$PREFIX"
if [[ ! -d "$PREFIX/src/.git" ]]; then
  git clone "$DNSTT_REPO" "$PREFIX/src"
else
  git -C "$PREFIX/src" pull --ff-only || true
fi
( cd "$PREFIX/src/dnstt-server" && go build -o "$PREFIX/dnstt-server" )
echo "    built: $PREFIX/dnstt-server"

# ---------------------------------------------------------------------------
# 3. Server keypair
# ---------------------------------------------------------------------------
if [[ ! -f "$PREFIX/server.key" ]]; then
  echo "==> Generating server keypair..."
  "$PREFIX/dnstt-server" -gen-key \
      -privkey-file "$PREFIX/server.key" \
      -pubkey-file  "$PREFIX/server.pub"
  chmod 600 "$PREFIX/server.key"
fi
SERVER_PUBKEY="$(cat "$PREFIX/server.pub")"

# ---------------------------------------------------------------------------
# 4. Dedicated SSH user
# ---------------------------------------------------------------------------
if ! id "$SSH_USER" >/dev/null 2>&1; then
  echo "==> Creating SSH user '$SSH_USER'..."
  useradd -m -s /bin/false "$SSH_USER"
  echo "==> Set a password for '$SSH_USER':"
  passwd "$SSH_USER"
fi

# Make sure the SSH server is running and permits the tunneling we need.
systemctl enable --now ssh

# ---------------------------------------------------------------------------
# 5. systemd service
# ---------------------------------------------------------------------------
echo "==> Installing systemd service..."
sed \
  -e "s#__PREFIX__#${PREFIX}#g" \
  -e "s#__DOMAIN__#${TUNNEL_DOMAIN}#g" \
  "$(dirname "$0")/dnstt-server.service" > /etc/systemd/system/dnstt-server.service

# Allow UDP/53 inbound.
iptables -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || \
  iptables -A INPUT -p udp --dport 53 -j ACCEPT

# If systemd-resolved is squatting on :53, free it.
if ss -lunp 2>/dev/null | grep -q ':53 '; then
  echo "==> Port 53 is in use; disabling systemd-resolved stub listener..."
  mkdir -p /etc/systemd/resolved.conf.d
  printf '[Resolve]\nDNSStubListener=no\n' > /etc/systemd/resolved.conf.d/no-stub.conf
  systemctl restart systemd-resolved || true
fi

systemctl daemon-reload
systemctl enable --now dnstt-server
sleep 1
systemctl --no-pager --full status dnstt-server | head -n 12 || true

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
cat <<EOF

============================================================================
 dnstt-server is running.

 Tunnel domain      : ${TUNNEL_DOMAIN}
 Forwarding to      : 127.0.0.1:22  (local SSH)
 SSH user           : ${SSH_USER}

 >>> SERVER PUBLIC KEY (enter this in the Android app) <<<
 ${SERVER_PUBKEY}

 Next:
   1. Make sure DNS delegation points ${TUNNEL_DOMAIN} at this VPS.
      See DNS-SETUP.md.
   2. Test from your laptop:
        dnstt-client -udp 1.1.1.1:53 \\
            -pubkey ${SERVER_PUBKEY} \\
            ${TUNNEL_DOMAIN} 127.0.0.1:7300
        ssh -p 7300 ${SSH_USER}@127.0.0.1
============================================================================
EOF
