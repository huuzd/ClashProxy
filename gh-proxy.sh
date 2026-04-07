#!/usr/bin/env bash
set -euo pipefail

# --- 配置参数 ---
APP_NAME="gh-proxy"
GH_REPO="huuzd/gh-proxy"
INSTALL_DIR="/opt/github-proxy"
BIN_PATH="${INSTALL_DIR}/${APP_NAME}"
SRC_FILE="${INSTALL_DIR}/${APP_NAME}.go"
ENV_FILE="${INSTALL_DIR}/.env"
USER_FILE="${INSTALL_DIR}/.users"
GO_LOCAL_DIR="${INSTALL_DIR}/go"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
PORT="9090"

log() { printf '[\033[32m%s\033[0m] %s\n' "$APP_NAME" "$*"; }
die() { printf '[\033[31m%s\033[0m] ERROR: %s\n' "$APP_NAME" "$*" >&2; exit 1; }

init_setup() {
    mkdir -p "$INSTALL_DIR"
    if [[ ! -f "$SRC_FILE" ]]; then
        log "正在同步远程源码..."
        wget -qO "$SRC_FILE" "https://raw.githubusercontent.com/${GH_REPO}/main/gh-proxy.go" || die "无法获取源码"
    fi
    [[ ! -f "$ENV_FILE" ]] && echo "PORT=$PORT" > "$ENV_FILE"
    touch "$USER_FILE"
}

ensure_go() {
    if [[ ! -x "${GO_LOCAL_DIR}/bin/go" ]]; then
        log "下载私有编译环境..."
        local arch="amd64"
        [[ "$(uname -m)" == "aarch64" ]] && arch="arm64"
        wget -qO /tmp/go.tar.gz "https://go.dev/dl/go1.22.5.linux-${arch}.tar.gz"
        tar -C "$INSTALL_DIR" -xzf /tmp/go.tar.gz
        rm -f /tmp/go.tar.gz
    fi
}

build_app() {
    log "正在编译并配置系统服务..."
    "${GO_LOCAL_DIR}/bin/go" build -trimpath -ldflags='-s -w' -o "$BIN_PATH" "$SRC_FILE"
    chmod +x "$BIN_PATH"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=GitHub Proxy Service
After=network.target
[Service]
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$BIN_PATH
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$APP_NAME"
    ln -sf "$INSTALL_DIR/$APP_NAME.sh" "/usr/local/bin/$APP_NAME"
    log "部署成功！"
}

show_help() {
    clear
    local ip=$(curl -s -m 5 https://api64.ipify.org || echo "YOUR_IP")
    echo -e "\033[33m====================================================\033[0m"
    echo -e "\033[1m           GitHub Raw Proxy 使用指南\033[0m"
    echo -e "\033[33m====================================================\033[0m"
    echo -e "\033[32m1. 代理链接格式：\033[0m"
    echo -e "   http://\033[36m用户名\033[0m:\033[36m密码\033[0m@\033[35m${ip}\033[0m:${PORT}/raw/\033[33m{账号}/{仓库}/{分支}/{路径}\033[0m"
    echo ""
    echo -e "\033[32m2. 转换示例：\033[0m"
    echo -e "   原: https://raw.githubusercontent.com/huuzd/gh-proxy/main/gh-proxy.sh"
    echo -e "   现: http://admin:123@${ip}:${PORT}/raw/huuzd/gh-proxy/main/gh-proxy.sh"
    echo ""
    echo -e "\033[31m3. 安全建议：\033[0m"
    echo -e "   为保障账号密码安全，强烈建议使用 Nginx/Caddy 对 \033[36mhttp://127.0.0.1:${PORT}\033[0m"
    echo -e "   进行反向代理并开启 \033[32mHTTPS\033[0m 访问。"
    echo ""
    echo -e "\033[32m4. 快捷管理：\033[0m"
    echo -e "   安装后，在终端任何位置输入 \033[1;34mgh-proxy\033[0m 即可再次打开此菜单。"
    echo -e "\033[33m====================================================\033[0m"
    read -p "按回车返回菜单..."
}

# --- 用户管理 & 菜单逻辑 (略，保持之前版本一致) ---
# ... (add_user, manage_users, uninstall 函数) ...

# 主菜单入口
while true; do
    clear
    echo "============================="
    echo "    GH-PROXY 交互管理工具"
    echo "============================="
    echo " 1. 新建用户"
    echo " 2. 用户管理"
    echo " 3. 重新编译程序"
    echo " 4. 查看使用说明"
    echo " 5. 卸载脚本"
    echo " 0. 退出菜单"
    echo "============================="
    read -p "选择: " choice
    case $choice in
        1) add_user ;;
        2) manage_users ;;
        3) ensure_go && build_app ;;
        4) show_help ;;
        5) uninstall ;;
        0) exit 0 ;;
    esac
done
