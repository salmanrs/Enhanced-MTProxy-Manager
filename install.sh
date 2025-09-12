#!/usr/bin/env bash
set -euo pipefail

# ===== Settings =====
INSTALL_DIR="/opt/mtproxy"
SERVICE_NAME="mtproxy"
USERS_JSON="/etc/mtproxy/users.json"
ENV_FILE="/etc/mtproxy/mtproxy.env"
QUOTA_DB="/var/lib/mtproxy/quota.db"

# Will build MTProxy C from upstream.
# Later you can replace these with your own repository/branch.
UPSTREAM_REPO="https://github.com/TelegramMessenger/MTProxy"
UPSTREAM_BRANCH="master"

# ===== Root check =====
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

# ===== Package manager =====
if command -v apt >/dev/null 2>&1; then
  PM=apt
  $PM update -y
  $PM install -y build-essential git curl ca-certificates jq wget \
    libssl-dev zlib1g-dev
elif command -v dnf >/dev/null 2>&1; then
  PM=dnf
  $PM install -y @development-tools git curl ca-certificates jq wget \
    openssl-devel zlib-devel
elif command -v yum >/dev/null 2>&1; then
  PM=yum
  $PM groupinstall -y "Development Tools"
  $PM install -y git curl ca-certificates jq wget openssl-devel zlib-devel
else
  echo "Unsupported distro: need apt/dnf/yum" >&2
  exit 1
fi

# ===== Directories =====
mkdir -p "$INSTALL_DIR" /etc/mtproxy /var/lib/mtproxy
chmod 755 /etc/mtproxy /var/lib/mtproxy

# ===== Fetch & build MTProxy (C) =====
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git clone --depth=1 -b "$UPSTREAM_BRANCH" "$UPSTREAM_REPO" "$TMP/MTProxy"
make -C "$TMP/MTProxy" -j"$(nproc)"

install -m 0755 "$TMP/MTProxy/objs/bin/mtproto-proxy" "$INSTALL_DIR/mtproto-proxy"
install -m 0644 "$TMP/MTProxy/objs/bin/proxy-secret" "$INSTALL_DIR/proxy-secret"
install -m 0644 "$TMP/MTProxy/objs/bin/proxy-multi.conf" "$INSTALL_DIR/proxy-multi.conf"

# ===== Config files =====
if [[ ! -f "$USERS_JSON" ]]; then
  install -m 0640 conf/users.json.example "$USERS_JSON"
fi
if [[ ! -f "$ENV_FILE" ]]; then
  install -m 0640 systemd/mtproxy.env.example "$ENV_FILE"
fi
touch "$QUOTA_DB"
chmod 640 "$USERS_JSON" "$ENV_FILE"
chown root:root "$USERS_JSON" "$ENV_FILE"

# ===== Management CLI =====
install -m 0755 scripts/mtcctl /usr/local/bin/mtcctl

# ===== systemd service =====
install -m 0644 systemd/mtproxy.service /etc/systemd/system/mtproxy.service
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

echo
echo "Enhanced MTProxy Manager installed."
echo "Config:  $USERS_JSON"
echo "Env:     $ENV_FILE"
echo "CLI:     mtcctl  (run 'mtcctl help')"
echo
echo "Examples:"
echo "  mtcctl add-user --name alice --secret 0123456789abcdef0123456789abcdef --mode ee --tls-domain www.google.com --quota 2gb --max-conns 3 --expire +30d"
echo "  mtcctl link --name alice --server YOUR_IP --port 443"
