#!/usr/bin/env bash
#
# install-server.sh — set up a DNS-over-Tunnel (dnstt) server on a VPS.
#
# Architecture:
#   Internet/DNS --(UDP/53)--> dnstt-server --(single stream)-->
#       127.0.0.1:1080  hev-socks5-server (SOCKS5 + UDP-in-TCP)  --> Internet
#
#   The Android app runs dnstt-client locally, which exposes a SOCKS5
#   endpoint, and routes the whole TUN device through it with hev's
#   tun2socks (udp: 'tcp'). SSH is NOT used — it cannot carry UDP/DNS
#   over dnstt's single reliable stream.
#
# Usage:
#   sudo bash install-server.sh <tunnel-domain> [proxy-user] [proxy-pass]
#
# Examples:
#   sudo bash install-server.sh t.example.com               # no auth
#   sudo bash install-server.sh t.example.com vpn s3cret     # with auth
#   sudo bash install-server.sh t.example.com vpn            # auto password
#
set -euo pipefail

TUNNEL_DOMAIN="${1:-}"
PROXY_USER="${2:-}"
PROXY_PASS="${3:-}"

PREFIX="/opt/dnstt"
GO_VERSION="1.22.5"
DNSTT_ZIP_URL="https://www.bamsoftware.com/software/dnstt/dnstt-20260501.zip"
HEV_REPO="https://github.com/heiher/hev-socks5-server"
SOCKS_PORT="1080"

if [[ -z "$TUNNEL_DOMAIN" ]]; then
  echo "ERROR: tunnel domain required." >&2
  echo "Usage: sudo bash install-server.sh <tunnel-domain> [proxy-user] [proxy-pass]" >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: please run as root (sudo)." >&2
  exit 1
fi

# If a user was given but no password, generate one.
if [[ -n "$PROXY_USER" && -z "$PROXY_PASS" ]]; then
  PROXY_PASS="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
fi

echo "==> Tunnel domain : $TUNNEL_DOMAIN"
if [[ -n "$PROXY_USER" ]]; then
  echo "==> Proxy auth    : enabled (user '$PROXY_USER')"
else
  echo "==> Proxy auth    : disabled (localhost-only SOCKS)"
fi
echo

# ---------------------------------------------------------------------------
# 1. Dependencies
# ---------------------------------------------------------------------------
echo "==> Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y git curl ca-certificates unzip iptables build-essential

# Install Go if not present.
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

mkdir -p "$PREFIX"

# ---------------------------------------------------------------------------
# 2. Build dnstt-server (from the release zip — the git server is flaky)
# ---------------------------------------------------------------------------
echo "==> Building dnstt-server..."
if [[ ! -d "$PREFIX/src/dnstt-server" ]]; then
  curl -fsSL "$DNSTT_ZIP_URL" -o /tmp/dnstt.zip
  rm -rf "$PREFIX/src"
  mkdir -p "$PREFIX/src"
  unzip -q /tmp/dnstt.zip -d /tmp/dnstt-src
  # The zip extracts to a versioned dir; move its contents into src/.
  mv /tmp/dnstt-src/*/* "$PREFIX/src/"
  rm -rf /tmp/dnstt-src /tmp/dnstt.zip
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
# 4. Build hev-socks5-server (SOCKS5 with UDP-in-TCP support)
# ---------------------------------------------------------------------------
echo "==> Building hev-socks5-server..."
if [[ ! -d "$PREFIX/hev-socks5-server/.git" ]]; then
  rm -rf "$PREFIX/hev-socks5-server"
  git clone --recursive "$HEV_REPO" "$PREFIX/hev-socks5-server"
else
  git -C "$PREFIX/hev-socks5-server" pull --ff-only || true
  git -C "$PREFIX/hev-socks5-server" submodule update --init --recursive
fi
make -C "$PREFIX/hev-socks5-server" -j"$(nproc)"
install -m 0755 "$PREFIX/hev-socks5-server/bin/hev-socks5-server" "$PREFIX/hev-socks5-server-bin"
echo "    built: $PREFIX/hev-socks5-server-bin"

# ---------------------------------------------------------------------------
# 5. hev-socks5-server config + systemd unit
# ---------------------------------------------------------------------------
echo "==> Writing hev-socks5-server config..."
{
  echo "main:"
  echo "  workers: 2"
  echo "  port: ${SOCKS_PORT}"
  echo "  listen-address: '127.0.0.1'"
  echo
  if [[ -n "$PROXY_USER" ]]; then
    echo "auth:"
    echo "  username: '${PROXY_USER}'"
    echo "  password: '${PROXY_PASS}'"
    echo
  fi
  echo "misc:"
  echo "  log-file: stderr"
  echo "  log-level: warn"
} > "$PREFIX/hev-socks5.yml"
chmod 600 "$PREFIX/hev-socks5.yml"

cat > /etc/systemd/system/hev-socks5.service <<EOF
[Unit]
Description=hev-socks5-server (SOCKS5 backend for dnstt)
After=network.target

[Service]
ExecStart=${PREFIX}/hev-socks5-server-bin ${PREFIX}/hev-socks5.yml
Restart=on-failure
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------------
# 6. dnstt-server systemd service (forwards to the SOCKS5 backend)
# ---------------------------------------------------------------------------
echo "==> Installing dnstt-server systemd service..."
sed \
  -e "s#__PREFIX__#${PREFIX}#g" \
  -e "s#__DOMAIN__#${TUNNEL_DOMAIN}#g" \
  -e "s#__SOCKS_PORT__#${SOCKS_PORT}#g" \
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
systemctl enable --now hev-socks5
systemctl enable --now dnstt-server
sleep 1
systemctl --no-pager --full status dnstt-server | head -n 10 || true

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
cat <<EOF

============================================================================
 dnstt-server + hev-socks5-server are running.

 Tunnel domain      : ${TUNNEL_DOMAIN}
 Forwarding to      : 127.0.0.1:${SOCKS_PORT}  (hev-socks5-server)
EOF
if [[ -n "$PROXY_USER" ]]; then
cat <<EOF
 Proxy username     : ${PROXY_USER}
 Proxy password     : ${PROXY_PASS}
EOF
else
cat <<EOF
 Proxy auth         : none (localhost-only)
EOF
fi
cat <<EOF

 >>> SERVER PUBLIC KEY (enter this in the Android app) <<<
 ${SERVER_PUBKEY}

 Enter these in the Android app:
   Tunnel domain    : ${TUNNEL_DOMAIN}
   Resolver         : 1.1.1.1:53  (or your preferred public resolver)
   Server pubkey    : ${SERVER_PUBKEY}
EOF
if [[ -n "$PROXY_USER" ]]; then
cat <<EOF
   Proxy username   : ${PROXY_USER}
   Proxy password   : ${PROXY_PASS}
EOF
fi
cat <<EOF

 Next:
   1. Make sure DNS delegation points ${TUNNEL_DOMAIN} at this VPS.
      See DNS-SETUP.md.
============================================================================
EOF
