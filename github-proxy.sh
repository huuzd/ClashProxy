#!/usr/bin/env bash
set -euo pipefail

APP_NAME="github-raw-proxy"
SRC_FILE="${SRC_FILE:-./github-raw-proxy.go}"
INSTALL_DIR="/opt/${APP_NAME}"
BIN_PATH="${INSTALL_DIR}/${APP_NAME}"
ENV_FILE="/etc/${APP_NAME}.env"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
PORT="${PORT:-9090}"

log() { printf '[%s] %s\n' "$APP_NAME" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$APP_NAME" "$*" >&2; exit 1; }

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请用 root 运行"
}

check_deps() {
  command -v go >/dev/null 2>&1 || die "未找到 go，请先安装 Go 1.20+"
  command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl"
}

check_source() {
  [[ -f "$SRC_FILE" ]] || die "未找到源码文件：$SRC_FILE"
}

prompt_auth() {
  local default_user="admin"
  local input_user input_pass input_pass2

  read -r -p "请输入用户名 [${default_user}]: " input_user
  AUTH_USER="${input_user:-$default_user}"

  while true; do
    read -r -s -p "请输入密码: " input_pass
    printf '\n'
    [[ -n "$input_pass" ]] || { log "密码不能为空"; continue; }
    read -r -s -p "请再次输入密码: " input_pass2
    printf '\n'
    [[ "$input_pass" == "$input_pass2" ]] || { log "两次密码不一致，请重试"; continue; }
    AUTH_PASS="$input_pass"
    break
  done
}

install_and_build() {
  mkdir -p "$INSTALL_DIR"
  cp -f "$SRC_FILE" "$INSTALL_DIR/main.go"
  cd "$INSTALL_DIR"
  GO111MODULE=off go build -trimpath -ldflags='-s -w' -o "$BIN_PATH" main.go
  chmod 755 "$BIN_PATH"
}

write_env_file() {
  cat > "$ENV_FILE" <<EOF
PORT=$PORT
BASIC_AUTH_USER=$AUTH_USER
BASIC_AUTH_PASS=$AUTH_PASS
EOF
  chmod 600 "$ENV_FILE"
}

write_service_file() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=GitHub Raw Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart=$BIN_PATH
Restart=always
RestartSec=2
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
}

restart_service() {
  systemctl daemon-reload
  systemctl enable --now "$APP_NAME"
  systemctl restart "$APP_NAME"
}

show_result() {
  log "安装完成"
  log "用户名：$AUTH_USER"
  log "二进制：$BIN_PATH"
  log "配置：$ENV_FILE"
  log "服务：$APP_NAME"
  log "查看状态：systemctl status $APP_NAME --no-pager"
  log "查看日志：journalctl -u $APP_NAME -f"
  log "本机测试：curl -u ${AUTH_USER}:*** http://127.0.0.1:$PORT/raw/{owner}/{repo}/{ref}/{path}"
}

main() {
  need_root
  check_deps
  check_source
  prompt_auth
  install_and_build
  write_env_file
  write_service_file
  restart_service
  show_result
}

main "$@"