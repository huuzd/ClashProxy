#!/usr/bin/env bash
set -euo pipefail

APP_NAME="github-raw-proxy"
CLI_NAME="hscgp"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SRC_FILE="${SRC_FILE:-./github-raw-proxy.go}"
INSTALL_DIR="/opt/${APP_NAME}"
BIN_PATH="${INSTALL_DIR}/${APP_NAME}"
ENV_FILE="/etc/${APP_NAME}.env"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
PORT="${PORT:-9090}"
GO_VERSION="${GO_VERSION:-1.24.2}"
GO_BASE_URL="${GO_BASE_URL:-https://go.dev/dl}"
ARCHIVE_NAME=""
GO_BIN=""
ACTION="install"
NEW_USER=""
NEW_PASS=""

log() { printf '[%s] %s\n' "$APP_NAME" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$APP_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
用法:
  $CLI_NAME                 一键安装/重装
  $CLI_NAME install         一键安装/重装
  $CLI_NAME set-pass 密码   仅修改密码
  $CLI_NAME set-auth 用户 密码  同时修改用户名和密码
  使用 $CLI_NAME 进入设置

环境变量:
  SRC_FILE=/path/to/github-raw-proxy.go
  PORT=9090
  GO_VERSION=1.24.2
  BASIC_AUTH_USER=admin
  BASIC_AUTH_PASS=123456
EOF
}

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请用 root 运行"
}

check_source() {
  [[ -f "$SRC_FILE" ]] || die "未找到源码文件：$SRC_FILE"
}

ensure_deps() {
  command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl"
  if command -v go >/dev/null 2>&1; then
    GO_BIN="$(command -v go)"
    return 0
  fi
  install_go
}

install_go() {
  local os arch url tmpdir
  os="linux"
  arch="amd64"
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l) arch="armv6l" ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac

  ARCHIVE_NAME="go${GO_VERSION}.${os}-${arch}.tar.gz"
  url="${GO_BASE_URL}/${ARCHIVE_NAME}"
  tmpdir="$(mktemp -d)"
  log "未找到 Go，开始安装 ${GO_VERSION}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$tmpdir/$ARCHIVE_NAME"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmpdir/$ARCHIVE_NAME" "$url"
  else
    die "需要 curl 或 wget 用于下载 Go"
  fi

  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$tmpdir/$ARCHIVE_NAME"
  rm -rf "$tmpdir"
  GO_BIN="/usr/local/go/bin/go"
  [[ -x "$GO_BIN" ]] || die "Go 安装失败"
}

load_existing_auth() {
  [[ -f "$ENV_FILE" ]] || die "未找到配置文件：$ENV_FILE"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  [[ -n "${BASIC_AUTH_USER:-}" ]] || die "配置文件中未找到用户名"
  [[ -n "${BASIC_AUTH_PASS:-}" ]] || die "配置文件中未找到密码"
}

prompt_auth() {
  local default_user="admin"
  local input_user input_pass input_pass2

  if [[ -n "${BASIC_AUTH_USER:-}" ]]; then
    default_user="$BASIC_AUTH_USER"
  fi

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
  "$GO_BIN" build -trimpath -ldflags='-s -w' -o "$BIN_PATH" main.go
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

install_cli_command() {
  local cli_path="/usr/local/bin/$CLI_NAME"
  cp -f "$SCRIPT_PATH" "$cli_path"
  chmod 755 "$cli_path"
}

restart_service() {
  systemctl daemon-reload
  systemctl enable --now "$APP_NAME"
  systemctl restart "$APP_NAME"
}

show_result() {
  log "安装完成"
  log "Go：$GO_BIN"
  log "命令：$CLI_NAME"
  log "用户名：$AUTH_USER"
  log "二进制：$BIN_PATH"
  log "配置：$ENV_FILE"
  log "服务：$APP_NAME"
  log "查看状态：systemctl status $APP_NAME --no-pager"
  log "查看日志：journalctl -u $APP_NAME -f"
  log "本机测试：curl -u ${AUTH_USER}:*** http://127.0.0.1:$PORT/raw/{owner}/{repo}/{ref}/{path}"
}

change_password() {
  local new_pass="$1"
  load_existing_auth
  AUTH_USER="$BASIC_AUTH_USER"
  AUTH_PASS="$new_pass"
  write_env_file
  systemctl daemon-reload
  systemctl restart "$APP_NAME"
  log "密码已更新"
  log "用户名：$AUTH_USER"
  log "配置：$ENV_FILE"
  log "重启：systemctl restart $APP_NAME"
}

change_auth() {
  local new_user="$1"
  local new_pass="$2"
  [[ -n "$new_user" ]] || die "用户名不能为空"
  [[ -n "$new_pass" ]] || die "密码不能为空"
  AUTH_USER="$new_user"
  AUTH_PASS="$new_pass"
  write_env_file
  systemctl daemon-reload
  systemctl restart "$APP_NAME"
  log "用户名和密码已更新"
  log "用户名：$AUTH_USER"
  log "配置：$ENV_FILE"
  log "重启：systemctl restart $APP_NAME"
}

main() {
  need_root

  case "${1:-}" in
    ""|install)
      ACTION="install"
      shift || true
      ;;
    set-pass|change-pass|passwd)
      ACTION="set-pass"
      shift || true
      ;;
    set-auth|change-auth)
      ACTION="set-auth"
      shift || true
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      die "未知参数：$1"
      ;;
  esac

  case "$ACTION" in
    install)
      check_source
      ensure_deps
      if [[ -n "${BASIC_AUTH_USER:-}" && -n "${BASIC_AUTH_PASS:-}" ]]; then
        AUTH_USER="$BASIC_AUTH_USER"
        AUTH_PASS="$BASIC_AUTH_PASS"
      else
        prompt_auth
      fi
      install_and_build
      write_env_file
      write_service_file
      install_cli_command
      restart_service
      show_result
      ;;
    set-pass)
      [[ -f "$ENV_FILE" ]] || die "未找到配置文件：$ENV_FILE"
      NEW_PASS="${1:-${NEW_PASS:-${BASIC_AUTH_PASS:-}}}"
      if [[ -z "$NEW_PASS" ]]; then
        read -r -s -p "请输入新密码: " NEW_PASS
        printf '\n'
      fi
      [[ -n "$NEW_PASS" ]] || die "密码不能为空"
      change_password "$NEW_PASS"
      ;;
    set-auth)
      [[ -f "$ENV_FILE" ]] || die "未找到配置文件：$ENV_FILE"
      NEW_USER="${1:-${NEW_USER:-${BASIC_AUTH_USER:-}}}"
      NEW_PASS="${2:-${NEW_PASS:-${BASIC_AUTH_PASS:-}}}"
      if [[ -z "$NEW_USER" ]]; then
        read -r -p "请输入新用户名: " NEW_USER
      fi
      if [[ -z "$NEW_PASS" ]]; then
        read -r -s -p "请输入新密码: " NEW_PASS
        printf '\n'
      fi
      change_auth "$NEW_USER" "$NEW_PASS"
      ;;
  esac
}

main "$@"