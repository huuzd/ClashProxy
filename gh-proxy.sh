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

# --- 2. 权限与目录初始化 ---
[[ "$EUID" -ne 0 ]] && { echo "错误：请使用 root 权限运行"; exit 1; }

mkdir -p "$INSTALL_DIR"
touch "$USER_FILE"
[[ ! -f "$ENV_FILE" ]] && echo "PORT=$PORT" > "$ENV_FILE"

# --- 3. 核心安装逻辑 (立即执行) ---
if [[ ! -f "$BIN_PATH" ]] || [[ ! -d "$GO_LOCAL_DIR" ]]; then
    echo "[gh-proxy] 检测到未安装，开始初始化..."
    
    # 下载源码
    echo "[gh-proxy] 同步远程源码..."
    wget -qO "$SRC_FILE" "https://raw.githubusercontent.com/${GH_REPO}/main/gh-proxy.go" || { echo "下载源码失败"; exit 1; }

    # 下载 Go 环境
    echo "[gh-proxy] 准备编译环境..."
    arch="amd64"; [[ "$(uname -m)" == "aarch64" ]] && arch="arm64"
    wget -qO- "https://go.dev/dl/go1.22.5.linux-${arch}.tar.gz" | tar -C "$INSTALL_DIR" -xz

    # 编译程序
    echo "[gh-proxy] 正在编译二进制文件..."
    "${GO_LOCAL_DIR}/bin/go" build -trimpath -ldflags='-s -w' -o "$BIN_PATH" "$SRC_FILE"
    chmod +x "$BIN_PATH"

    # 写入系统服务
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
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$APP_NAME"

    # --- 关键改进：立即生成全局命令 ---
    # 将此脚本同步到安装目录并建立软链接
    cp "$0" "${INSTALL_DIR}/${APP_NAME}.sh"
    chmod +x "${INSTALL_DIR}/${APP_NAME}.sh"
    ln -sf "${INSTALL_DIR}/${APP_NAME}.sh" "/usr/local/bin/${APP_NAME}"
    
    # --- 关键改进：清理临时脚本 ---
    if [[ "$0" == "/tmp/gh-proxy.sh" ]]; then
        rm -f "/tmp/gh-proxy.sh"
        echo "[gh-proxy] 临时安装脚本已清理。"
    fi

    echo "[gh-proxy] 安装成功！已生成全局命令: ${APP_NAME}"
    sleep 1
fi

# --- 4. 交互菜单 (进入循环) ---
while true; do
    clear
    echo "============================="
    echo "    GH-PROXY 交互管理工具"
    echo "============================="
    echo " 1. 新建用户"
    echo " 2. 修改用户"
    echo " 3. 使用说明"
    echo " 4. 重新安装"
    echo " 5. 卸载脚本"
    echo " 0. 退出脚本"
    echo "============================="
    read -p "请输入选项 [0-5]: " choice

    case "${choice:-}" in
        1)
            read -p "用户名: " u; read -s -p "密码: " p; echo
            [[ -n "$u" && -n "$p" ]] && { echo "$u:$p" >> "$USER_FILE"; systemctl restart "$APP_NAME"; echo "添加成功"; }
            read -p "按回车继续..."
            ;;
        2)
            if [[ ! -s "$USER_FILE" ]]; then echo "暂无用户"; sleep 1; continue; fi
            users=($(awk -F: '{print $1}' "$USER_FILE"))
            for i in "${!users[@]}"; do echo "$((i+1)). ${users[$i]}"; done
            read -p "请选择编号: " idx
            target="${users[$((idx-1))]:-}"
            if [[ -n "$target" ]]; then
                echo "1. 修改密码  2. 删除用户  0. 返回"
                read -p "操作: " opt
                [[ "$opt" == "1" ]] && { read -s -p "新密码: " p; echo; sed -i "s/^$target:.*/$target:$p/" "$USER_FILE"; }
                [[ "$opt" == "2" ]] && sed -i "/^$target:/d" "$USER_FILE"
                systemctl restart "$APP_NAME" && echo "操作完成"
            fi
            read -p "按回车继续..."
            ;;
        3)
            clear
            ip=$(curl -s -m 5 https://api64.ipify.org || echo "服务器IP")
            echo "使用说明："
            echo "1. 链接格式: http://用户名:密码@${ip}:${PORT}/raw/ 替换raw链接中的 https://raw.githubusercontent.com/ 部分"
            echo "2. 快捷管理: 以后直接输入 gh-proxy 命令即可再次进入此菜单"
            echo "3. 安全建议: 建议使用 Nginx 反代并开启HTTPS"
            read -p "按回车返回..."
            ;;
        4)
            echo "重新编译..."
            "${GO_LOCAL_DIR}/bin/go" build -trimpath -ldflags='-s -w' -o "$BIN_PATH" "$SRC_FILE"
            systemctl restart "$APP_NAME" && echo "编译完成并重启"
            sleep 1
            ;;
        5)
            read -p "确定卸载吗？(y/N): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                systemctl stop "$APP_NAME" || true
                systemctl disable "$APP_NAME" || true
                rm -f "$SERVICE_FILE" "/usr/local/bin/$APP_NAME"
                rm -rf "$INSTALL_DIR"
                echo "卸载完成，所有数据已清理。"
                exit 0
            fi
            ;;
        0) exit 0 ;;
    esac
done
