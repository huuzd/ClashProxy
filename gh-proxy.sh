#!/usr/bin/env bash
set -euo pipefail

# --- 1. 配置参数 ---
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
LISTEN_HOST="127.0.0.1"
GO_VERSION="1.22.5"

# --- 2. 基础检查 ---
[[ "${EUID}" -ne 0 ]] && { echo "错误：请使用 root 权限运行"; exit 1; }

mkdir -p "$INSTALL_DIR"
touch "$USER_FILE"
chmod 600 "$USER_FILE"

if [[ ! -f "$ENV_FILE" ]]; then
    cat > "$ENV_FILE" <<EOF
PORT=${PORT}
LISTEN_HOST=${LISTEN_HOST}
EOF
    chmod 600 "$ENV_FILE"
fi

# --- 3. 工具函数 ---
pause() {
    read -r -p "按回车继续..."
}

require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "错误：缺少命令 $cmd"
        exit 1
    }
}

is_valid_username() {
    local u="$1"
    [[ "$u" =~ ^[A-Za-z0-9_.-]+$ ]]
}

user_exists() {
    local u="$1"
    awk -F: -v user="$u" '$1==user{found=1} END{exit !found}' "$USER_FILE"
}

download_source() {
    echo "[gh-proxy] 同步远程源码..."
    wget -qO "$SRC_FILE" "https://raw.githubusercontent.com/${GH_REPO}/main/gh-proxy.go" || {
        echo "下载源码失败"
        exit 1
    }
    chmod 644 "$SRC_FILE"
}

install_go_local() {
    echo "[gh-proxy] 准备编译环境..."
    local arch="amd64"
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *)
            echo "不支持的系统架构: $(uname -m)"
            exit 1
            ;;
    esac

    rm -rf "$GO_LOCAL_DIR"
    wget -qO- "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" | tar -C "$INSTALL_DIR" -xz
}

build_binary() {
    [[ -x "${GO_LOCAL_DIR}/bin/go" ]] || {
        echo "Go 编译环境不存在，请先安装"
        exit 1
    }

    [[ -f "$SRC_FILE" ]] || {
        echo "源码不存在，请先同步源码"
        exit 1
    }

    echo "[gh-proxy] 正在编译二进制文件..."
    "${GO_LOCAL_DIR}/bin/go" build -trimpath -ldflags='-s -w' -o "$BIN_PATH" "$SRC_FILE"
    chmod 755 "$BIN_PATH"
}

write_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=GitHub Proxy Service
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$BIN_PATH
Restart=always
RestartSec=3

# 基础安全项
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=$INSTALL_DIR

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable --now "$APP_NAME"
}

install_global_command() {
    cp "$0" "${INSTALL_DIR}/${APP_NAME}.sh"
    chmod 755 "${INSTALL_DIR}/${APP_NAME}.sh"
    ln -sf "${INSTALL_DIR}/${APP_NAME}.sh" "/usr/local/bin/${APP_NAME}"
}

initial_install() {
    echo "[gh-proxy] 检测到未安装，开始初始化..."

    require_cmd wget
    require_cmd tar
    require_cmd systemctl

    download_source
    install_go_local
    build_binary
    write_service
    install_global_command

    if [[ "$0" == "/tmp/gh-proxy.sh" ]]; then
        rm -f "/tmp/gh-proxy.sh"
        echo "[gh-proxy] 临时安装脚本已清理。"
    fi

    echo "[gh-proxy] 安装成功！已生成全局命令: ${APP_NAME}"
}

show_usage() {
    clear
    echo "使用说明："
    echo "1. 链接格式："
    echo "   https://用户名:密码@你的域名/raw/owner/repo/branch/file"
    echo
    echo "2. 使用方式："
    echo "   将原始 raw.githubusercontent.com 链接中的"
    echo "   https://raw.githubusercontent.com/"
    echo "   替换为"
    echo "   https://用户名:密码@你的域名/raw/"
    echo
    echo "3. 说明："
    echo "   - 当前程序默认仅监听 ${LISTEN_HOST}:${PORT}"
    echo "   - 请通过你自己的 Nginx / Caddy 反代访问"
    echo "   - 若你修改了 .env 中的端口或监听地址，请重启服务"
    echo
    pause
}

add_user() {
    local u p

    read -r -p "用户名: " u
    read -r -s -p "密码: " p
    echo

    if [[ -z "$u" || -z "$p" ]]; then
        echo "用户名和密码不能为空"
        pause
        return
    fi

    if ! is_valid_username "$u"; then
        echo "用户名非法：仅允许字母、数字、点、下划线、横线"
        pause
        return
    fi

    if user_exists "$u"; then
        echo "用户已存在，请使用“修改用户”功能"
        pause
        return
    fi

    echo "${u}:${p}" >> "$USER_FILE"
    chmod 600 "$USER_FILE"
    systemctl restart "$APP_NAME"

    echo "添加成功"
    pause
}

modify_user() {
    if [[ ! -s "$USER_FILE" ]]; then
        echo "暂无用户"
        sleep 1
        return
    fi

    mapfile -t users < <(awk -F: 'NF>=1 && $1 !~ /^#/ && $1 != "" {print $1}' "$USER_FILE")

    if [[ "${#users[@]}" -eq 0 ]]; then
        echo "暂无有效用户"
        sleep 1
        return
    fi

    echo "当前用户："
    for i in "${!users[@]}"; do
        echo "$((i+1)). ${users[$i]}"
    done

    read -r -p "请选择编号: " idx

    if [[ ! "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#users[@]} )); then
        echo "编号无效"
        pause
        return
    fi

    local target="${users[$((idx-1))]}"
    local opt
    echo "1. 修改密码"
    echo "2. 删除用户"
    echo "0. 返回"
    read -r -p "操作: " opt

    case "${opt:-}" in
        1)
            local p
            read -r -s -p "新密码: " p
            echo
            if [[ -z "$p" ]]; then
                echo "密码不能为空"
                pause
                return
            fi

            awk -F: -v user="$target" -v pass="$p" 'BEGIN{OFS=":"} $1==user{$2=pass} {print}' "$USER_FILE" > "${USER_FILE}.tmp"
            mv "${USER_FILE}.tmp" "$USER_FILE"
            chmod 600 "$USER_FILE"
            systemctl restart "$APP_NAME"
            echo "密码修改完成"
            ;;
        2)
            awk -F: -v user="$target" '$1!=user {print}' "$USER_FILE" > "${USER_FILE}.tmp"
            mv "${USER_FILE}.tmp" "$USER_FILE"
            chmod 600 "$USER_FILE"
            systemctl restart "$APP_NAME"
            echo "用户已删除"
            ;;
        0)
            return
            ;;
        *)
            echo "无效操作"
            ;;
    esac

    pause
}

rebuild_local() {
    echo "[gh-proxy] 重新编译本地源码..."
    build_binary
    systemctl restart "$APP_NAME"
    echo "编译完成并重启"
    sleep 1
}

update_and_reinstall() {
    echo "[gh-proxy] 更新源码并重新编译..."
    download_source
    build_binary
    systemctl restart "$APP_NAME"
    echo "更新完成并重启"
    sleep 1
}

show_service_status() {
    clear
    systemctl --no-pager --full status "$APP_NAME" || true
    echo
    pause
}

uninstall_all() {
    read -r -p "确定卸载吗？(y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        return
    fi

    systemctl stop "$APP_NAME" || true
    systemctl disable "$APP_NAME" || true
    rm -f "$SERVICE_FILE" "/usr/local/bin/$APP_NAME"
    systemctl daemon-reload || true
    rm -rf "$INSTALL_DIR"

    echo "卸载完成，所有数据已清理。"
    exit 0
}

# --- 4. 首次安装逻辑 ---
if [[ ! -x "$BIN_PATH" ]] || [[ ! -d "$GO_LOCAL_DIR" ]] || [[ ! -f "$SERVICE_FILE" ]]; then
    initial_install
    sleep 1
fi

# --- 5. 交互菜单 ---
while true; do
    clear
    echo "============================="
    echo "    GH-PROXY 交互管理工具"
    echo "============================="
    echo " 1. 新建用户"
    echo " 2. 修改用户"
    echo " 3. 使用说明"
    echo " 4. 重新编译"
    echo " 5. 更新源码并重编译"
    echo " 6. 查看服务状态"
    echo " 7. 卸载脚本"
    echo " 0. 退出脚本"
    echo "============================="
    read -r -p "请输入选项 [0-7]: " choice

    case "${choice:-}" in
        1) add_user ;;
        2) modify_user ;;
        3) show_usage ;;
        4) rebuild_local ;;
        5) update_and_reinstall ;;
        6) show_service_status ;;
        7) uninstall_all ;;
        0) exit 0 ;;
        *) echo "无效选项"; sleep 1 ;;
    esac
done
