#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/mtproxy"
SERVICE_NAME="mtproxy"
USERS_JSON="/etc/mtproxy/users.json"
ENV_FILE="/etc/mtproxy/mtproxy.env"
QUOTA_DB="/var/lib/mtproxy/quota.db"

UPSTREAM_REPO="https://github.com/TelegramMessenger/MTProxy"
UPSTREAM_BRANCH="master"

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo)."
    exit 1
  fi
}

install_proxy() {
  echo "[*] Installing MTProxy..."
  if command -v apt >/dev/null 2>&1; then
    apt update -y
    apt install -y build-essential git curl jq wget libssl-dev zlib1g-dev iptables
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y @development-tools git curl jq wget openssl-devel zlib-devel iptables
  fi

  mkdir -p "$INSTALL_DIR" /etc/mtproxy /var/lib/mtproxy

  TMP="$(mktemp -d)"
  git clone --depth=1 -b "$UPSTREAM_BRANCH" "$UPSTREAM_REPO" "$TMP/MTProxy"
  sed -i 's#objs/lib/libkbdb\.a##g' "$TMP/MTProxy/Makefile"
  make -C "$TMP/MTProxy" -j"$(nproc)"

  install -m 0755 "$TMP/MTProxy/objs/bin/mtproto-proxy" "$INSTALL_DIR/mtproto-proxy"
  install -m 0644 "$TMP/MTProxy/objs/bin/proxy-secret" "$INSTALL_DIR/proxy-secret"
  install -m 0644 "$TMP/MTProxy/objs/bin/proxy-multi.conf" "$INSTALL_DIR/proxy-multi.conf"

  [ ! -f "$USERS_JSON" ] && echo "[]" > "$USERS_JSON"
  [ ! -f "$ENV_FILE" ] && cat <<EOF > "$ENV_FILE"
PORT=443
STATS_PORT=8888
AD_TAG=
EOF
  touch "$QUOTA_DB"

  cat >/etc/systemd/system/mtproxy.service <<EOF
[Unit]
Description=MTProxy (C) with external manager
After=network.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart=$INSTALL_DIR/mtproto-proxy -u nobody -p \${STATS_PORT} -H \${PORT} --aes-pwd $INSTALL_DIR/proxy-secret $INSTALL_DIR/proxy-multi.conf \${AD_TAG:+-P \${AD_TAG}}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"
}

view_links() {
  SERVER_IP=$(curl -s ifconfig.me || echo "YOUR_IP")
  PORT=$(grep '^PORT=' "$ENV_FILE" | cut -d= -f2)
  jq -r ".[] | \"tg://proxy?server=$SERVER_IP&port=$PORT&secret=\(.secret)\"" "$USERS_JSON"
}

add_user() {
  read -rp "Enter username: " NAME
  SECRET=$(openssl rand -hex 16)
  read -rp "Expiry days (e.g. 7): " DAYS
  EXP=$(date -d "+$DAYS days" +%s)
  read -rp "Max connections: " MAXCONN
  read -rp "Quota (e.g. 1gb, 500mb, 0 for unlimited): " QUOTA

  NEW=$(jq -n --arg n "$NAME" --arg s "$SECRET" --argjson e "$EXP" --arg mc "$MAXCONN" --arg q "$QUOTA" '{name:$n, secret:$s, expire:$e, maxconns:$mc, quota:$q}')
  TMP=$(mktemp)
  jq ". + [$NEW]" "$USERS_JSON" >"$TMP" && mv "$TMP" "$USERS_JSON"
  systemctl restart "$SERVICE_NAME"
  echo "User added. Secret: $SECRET"
}

revoke_user() {
  read -rp "Enter username to revoke: " NAME
  TMP=$(mktemp)
  jq "del(.[] | select(.name==\"$NAME\"))" "$USERS_JSON" >"$TMP" && mv "$TMP" "$USERS_JSON"
  systemctl restart "$SERVICE_NAME"
  echo "User revoked."
}

change_expiry() {
  read -rp "Enter username: " NAME
  read -rp "Expiry days: " DAYS
  EXP=$(date -d "+$DAYS days" +%s)
  TMP=$(mktemp)
  jq "(.[] | select(.name==\"$NAME\") | .expire) |= $EXP" "$USERS_JSON" >"$TMP" && mv "$TMP" "$USERS_JSON"
  systemctl restart "$SERVICE_NAME"
  echo "Expiry updated."
}

change_limits() {
  read -rp "Enter username: " NAME
  read -rp "New max connections: " MAXCONN
  TMP=$(mktemp)
  jq "(.[] | select(.name==\"$NAME\") | .maxconns) |= \"$MAXCONN\"" "$USERS_JSON" >"$TMP" && mv "$TMP" "$USERS_JSON"
  systemctl restart "$SERVICE_NAME"
  echo "Connection limit updated."
}

change_quota() {
  read -rp "Enter username: " NAME
  read -rp "New quota (e.g. 2gb, 0 for unlimited): " QUOTA
  TMP=$(mktemp)
  jq "(.[] | select(.name==\"$NAME\") | .quota) |= \"$QUOTA\"" "$USERS_JSON" >"$TMP" && mv "$TMP" "$USERS_JSON"
  systemctl restart "$SERVICE_NAME"
  echo "Quota updated."
}

firewall_rules() {
  PORT=$(grep '^PORT=' "$ENV_FILE" | cut -d= -f2)
  iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT
  iptables -A INPUT -p udp --dport "$PORT" -j ACCEPT
  echo "Firewall rules added for port $PORT."
}

uninstall_proxy() {
  systemctl stop "$SERVICE_NAME"
  systemctl disable "$SERVICE_NAME"
  rm -f /etc/systemd/system/mtproxy.service
  rm -rf "$INSTALL_DIR" "$USERS_JSON" "$ENV_FILE" "$QUOTA_DB"
  systemctl daemon-reload
  echo "MTProxy uninstalled."
}

menu() {
  while true; do
    clear
    echo "You have already installed MTProtoProxy! What do you want to do?"
    echo " 1) View all connection links"
    echo " 2) Upgrade proxy software"
    echo " 3) Change AD TAG"
    echo " 4) Add a secret"
    echo " 5) Revoke a secret"
    echo " 6) Change user connection limits"
    echo " 7) Change user expiry date"
    echo " 8) Change user quota options"
    echo " 9) Generate firewall rules"
    echo "10) Uninstall Proxy"
    echo "11) About"
    echo " * ) Exit"
    read -rp "Please enter a number: " choice

    case $choice in
      1) view_links ;;
      2) install_proxy ;;
      3) nano "$ENV_FILE"; systemctl restart "$SERVICE_NAME" ;;
      4) add_user ;;
      5) revoke_user ;;
      6) change_limits ;;
      7) change_expiry ;;
      8) change_quota ;;
      9) firewall_rules ;;
      10) uninstall_proxy; exit 0 ;;
      11) echo "Enhanced MTProxy Manager (based on official MTProxy)" ;;
      *) exit 0 ;;
    esac
    read -rp "Press enter to continue..." _
  done
}

check_root
if [[ ! -x "$INSTALL_DIR/mtproto-proxy" ]]; then
  install_proxy
fi
menu
