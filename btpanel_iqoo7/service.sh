#!/system/bin/sh
#
# iQOO 7 宝塔面板开机自启服务脚本
# 自动安装 + 开机自启宝塔面板服务
#

MODDIR=${0%/*}
BTPANEL_BIN=""
BTPANEL_INSTALL_DIR="/data/btpanel"
BTPANEL_FLAG_DIR="${BTPANEL_INSTALL_DIR}/.module_flags"
BTPANEL_STATE_FILE="${BTPANEL_FLAG_DIR}/state"
INSTALL_LOCK="${BTPANEL_FLAG_DIR}/install.lock"
INSTALL_LOG="${BTPANEL_INSTALL_DIR}/install.log"

# 等待系统启动完成
wait_for_boot_complete() {
    local timeout=60
    local elapsed=0
    while [ "$(getprop sys.boot_completed)" != "1" ]; do
        sleep 2
        elapsed=$((elapsed + 2))
        if [ $elapsed -ge $timeout ]; then break; fi
    done
    sleep 5
}

# 等待网络就绪（ping 可能被 SELinux 禁止，多重检测）
wait_for_network() {
    local timeout=120
    local elapsed=0
    while true; do
        # 方法 1: ping 探测
        if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1; then break; fi
        # 方法 2: 检查 getprop 网络状态
        [ "$(getprop net.dns1 2>/dev/null)" != "" ] && break
        [ "$(getprop dhcp.wlan0.gateway 2>/dev/null)" != "" ] && break
        # 方法 3: 检查路由表有无默认路由
        if [ -f /proc/net/route ]; then
            if grep -q '^wlan0\|^eth0\|^rmnet' /proc/net/route 2>/dev/null; then break; fi
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        if [ $elapsed -ge $timeout ]; then break; fi
    done
}

# 查找宝塔面板安装路径
find_btpanel() {
    local paths="
        /www/server/panel/bt
        /data/btpanel/bt
        /data/adb/btpanel/bt
        /data/btpanel/panel/bt
        /data/linux/bt
        /data/linux/www/server/panel/bt
        /usr/bin/bt
    "
    for p in $paths; do
        if [ -f "$p" ] && [ -x "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    local which_bt=$(command -v bt 2>/dev/null)
    if [ -n "$which_bt" ] && [ -f "$which_bt" ]; then
        echo "$which_bt"
        return 0
    fi
    return 1
}

# 检查是否存在残留目录（目录在但核心文件缺失，视为未完整安装）
has_btpanel_residue() {
    # 有 /www/server/panel 目录但缺少核心 class 或 bt 脚本 → 残留
    if [ -d "/www/server/panel" ]; then
        if [ ! -f "/www/server/panel/class/panelPlugin.py" ] || [ ! -x "/www/server/panel/bt" ]; then
            return 0
        fi
    fi
    if [ -d "${BTPANEL_INSTALL_DIR}/panel" ]; then
        if [ ! -f "${BTPANEL_INSTALL_DIR}/panel/class/panelPlugin.py" ] || [ ! -x "${BTPANEL_INSTALL_DIR}/bt" ]; then
            return 0
        fi
    fi
    return 1
}

# 清理残留目录（仅清理已判定为残留的路径，避免误删完整安装）
cleanup_btpanel_residue() {
    mkdir -p "${BTPANEL_INSTALL_DIR}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 检测到宝塔面板残留目录，开始清理..." >> "${INSTALL_LOG}" 2>/dev/null || true
    # 先尝试用残留的 bt stop 停掉可能存在的进程
    for p in /www/server/panel/bt "${BTPANEL_INSTALL_DIR}/bt"; do
        if [ -x "$p" ]; then "$p" stop >/dev/null 2>&1; fi
    done
    # 清理进程
    pkill -f "BT-Panel" >/dev/null 2>&1 || true
    pkill -f "gunicorn.*panel" >/dev/null 2>&1 || true
    # 清理锁文件
    rm -f "$INSTALL_LOCK" "${BTPANEL_FLAG_DIR}/installed"
    # 清理残留目录（保留日志）
    if [ -d "/www/server/panel" ] && [ ! -f "/www/server/panel/class/panelPlugin.py" ]; then
        rm -rf /www/server/panel 2>/dev/null || true
    fi
    if [ -d "${BTPANEL_INSTALL_DIR}/panel" ] && [ ! -f "${BTPANEL_INSTALL_DIR}/panel/class/panelPlugin.py" ]; then
        rm -rf "${BTPANEL_INSTALL_DIR}/panel" 2>/dev/null || true
    fi
}

# 检查面板是否已完整安装
is_btpanel_installed() {
    # 1. 可执行 bt 命令存在
    local bt_bin=$(find_btpanel)
    # 2. 面板核心 class 文件存在（区分完整安装 vs 残留空目录）
    local panel_ok=0
    if [ -d "/www/server/panel" ] && [ -f "/www/server/panel/class/panelPlugin.py" ]; then
        panel_ok=1
    fi
    if [ -d "${BTPANEL_INSTALL_DIR}/panel" ] && [ -f "${BTPANEL_INSTALL_DIR}/panel/class/panelPlugin.py" ]; then
        panel_ok=1
    fi
    if [ -d "/data/adb/btpanel/panel" ] && [ -f "/data/adb/btpanel/panel/class/panelPlugin.py" ]; then
        panel_ok=1
    fi
    if [ -d "/data/linux/www/server/panel" ] && [ -f "/data/linux/www/server/panel/class/panelPlugin.py" ]; then
        panel_ok=1
    fi

    if [ -n "$bt_bin" ] && [ $panel_ok -eq 1 ]; then
        return 0
    fi

    return 1
}

# 下载文件
download_file() {
    local url="$1"
    local output="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -sSLo "$output" "$url" --connect-timeout 30 --retry 3
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$output" "$url" --timeout=30 --tries=3
    else
        return 1
    fi
}

# 设置默认账号密码
setup_default_credentials() {
    # 等待面板初始化完成
    sleep 3
    local bt_bin=$(find_btpanel)
    [ -z "$bt_bin" ] && return 1

    # 修改默认密码为 admin
    echo "admin" | "$bt_bin" 5 >/dev/null 2>&1
    # 修改默认账号为 admin (bt 命令的 6 是修改用户名)
    echo "admin" | "$bt_bin" 6 >/dev/null 2>&1
    return 0
}

# 自动安装宝塔面板
auto_install_btpanel() {
    # 创建标志目录
    mkdir -p "${BTPANEL_FLAG_DIR}"

    # 创建安装锁，防止重复安装
    echo "$$" > "$INSTALL_LOCK"

    # 日志轮转：超过 512KB 时只保留最后 1000 行
    if [ -f "$INSTALL_LOG" ]; then
        local log_size=$(wc -c < "$INSTALL_LOG" 2>/dev/null || echo 0)
        if [ "$log_size" -gt 524288 ]; then
            tail -n 1000 "$INSTALL_LOG" > "${INSTALL_LOG}.tmp" 2>/dev/null && mv "${INSTALL_LOG}.tmp" "$INSTALL_LOG"
        fi
    fi

    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 开始自动安装宝塔面板..."

        # 确保基础工具
        if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
            echo "[ERROR] 未找到 curl 或 wget，无法下载安装包"
            rm -f "$INSTALL_LOCK"
            exit 1
        fi

        # 确保 /www 目录可写
        mkdir -p /www
        chmod 755 /www

        # 下载官方安装脚本
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 正在下载宝塔面板安装脚本..."
        local install_script="/tmp/bt_install_panel.sh"
        if ! download_file "https://download.bt.cn/install/install_panel.sh" "$install_script"; then
            echo "[ERROR] 下载安装脚本失败"
            rm -f "$INSTALL_LOCK"
            exit 1
        fi

        chmod 0755 "$install_script"

        # 执行安装（使用 ed8484bec 官方论坛码）
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 开始安装宝塔面板（此过程可能需要 3-10 分钟）..."
        echo "y" | bash "$install_script" ed8484bec >> "${INSTALL_LOG}" 2>&1

        # 检查安装结果
        if is_btpanel_installed; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 宝塔面板安装成功！"

            # 设置默认账号密码
            setup_default_credentials

            # 启动面板
            local bt_bin=$(find_btpanel)
            if [ -n "$bt_bin" ]; then
                # 停止面板端口冲突检测（非交互式）
                export BT_IGNORE=1
                nohup "$bt_bin" start >/dev/null 2>&1 &
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 宝塔面板已启动"
            fi

            # 创建安装完成标志
            touch "${BTPANEL_FLAG_DIR}/installed"
        else
            echo "[ERROR] 宝塔面板安装失败，请检查日志: ${INSTALL_LOG}"
        fi

        rm -f "$INSTALL_LOCK"
    } >> "${INSTALL_LOG}" 2>&1 &

    # 返回前台
    return 0
}

# 启动宝塔面板
start_btpanel() {
    local bt_bin="$1"
    if [ -z "$bt_bin" ]; then return 1; fi

    # 检查是否已运行
    local pid_file=""
    for f in /www/server/panel/data/bt.pid /data/btpanel/bt.pid; do
        if [ -f "$f" ]; then pid_file="$f"; break; fi
    done

    if [ -n "$pid_file" ]; then
        local pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0  # 已在运行
        fi
    fi

    # 写入状态：启动中
    mkdir -p "${BTPANEL_FLAG_DIR}"
    echo "starting" > "${BTPANEL_STATE_FILE}"

    # 启动面板
    export BT_IGNORE=1
    nohup "$bt_bin" start >/dev/null 2>&1 &

    # 等待启动完成（最多 30 秒），成功后状态改回空（由检测自动显示运行中）
    (
        local waited=0
        while [ $waited -lt 30 ]; do
            sleep 3
            waited=$((waited + 3))
            local started=0
            for f in /www/server/panel/data/bt.pid /data/btpanel/bt.pid; do
                if [ -f "$f" ]; then
                    local p=$(cat "$f" 2>/dev/null)
                    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then started=1; break; fi
                fi
            done
            if [ $started -eq 1 ]; then break; fi
        done
        rm -f "${BTPANEL_STATE_FILE}"
        update_module_desc
    ) &
    return 0
}

# 停止宝塔面板（供 action.sh / btpanel 命令共享调用）
stop_btpanel() {
    local bt_bin="$1"
    if [ -z "$bt_bin" ]; then bt_bin=$(find_btpanel); fi
    if [ -z "$bt_bin" ]; then return 1; fi

    # 写入状态：停止中
    mkdir -p "${BTPANEL_FLAG_DIR}"
    echo "stopping" > "${BTPANEL_STATE_FILE}"

    export BT_IGNORE=1
    "$bt_bin" stop >/dev/null 2>&1

    # 等进程真正退出（最多 20 秒）
    (
        local waited=0
        while [ $waited -lt 20 ]; do
            sleep 2
            waited=$((waited + 2))
            local running=0
            for f in /www/server/panel/data/bt.pid /data/btpanel/bt.pid; do
                if [ -f "$f" ]; then
                    local p=$(cat "$f" 2>/dev/null)
                    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then running=1; break; fi
                fi
            done
            pgrep -f "BT-Panel" >/dev/null 2>&1 && running=1
            if [ $running -eq 0 ]; then break; fi
        done
        # 兜底：强制杀残留
        pkill -f "BT-Panel" >/dev/null 2>&1 || true
        pkill -f "gunicorn.*panel" >/dev/null 2>&1 || true
        rm -f "${BTPANEL_STATE_FILE}"
        update_module_desc
    ) &
    return 0
}

# 更新模块介绍信息
update_module_desc() {
    local module_dir="/data/adb/modules/btpanel_iqoo7"
    local module_prop="$module_dir/module.prop"
    [ ! -d "$module_dir" ] && return

    # 获取局域网 IP
    local ip=""
    ip=$(ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    [ -z "$ip" ] && ip=$(ip addr show eth0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    [ -z "$ip" ] && ip=$(getprop dhcp.wlan0.ipaddress 2>/dev/null)
    [ -z "$ip" ] && ip="无法获取"

    # ===== 1. 先读取过渡状态文件（优先级最高）=====
    local trans_state=""
    if [ -f "$BTPANEL_STATE_FILE" ]; then
        trans_state=$(cat "$BTPANEL_STATE_FILE" 2>/dev/null)
    fi

    # ===== 2. 再判断安装 + 运行状态 =====
    local status="未安装"
    local status_icon="✘"
    local bt_bin=$(find_btpanel)

    if [ -n "$bt_bin" ]; then
        local pid_file=""
        for f in /www/server/panel/data/bt.pid /data/btpanel/bt.pid; do
            if [ -f "$f" ]; then pid_file="$f"; break; fi
        done
        if [ -n "$pid_file" ]; then
            local pid=$(cat "$pid_file" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                status="运行中"
                status_icon="✔"
            else
                status="已停止"
                status_icon="✘"
            fi
        else
            # 有 bt 但无 pid 文件：已安装但没启动
            status="已停止"
            status_icon="✘"
        fi
    elif [ -f "${BTPANEL_FLAG_DIR}/installed" ]; then
        status="安装完成"
        status_icon="●"
    elif [ -f "$INSTALL_LOCK" ]; then
        status="安装中..."
        status_icon="↓"
    fi

    # ===== 3. 过渡状态覆盖最终状态 =====
    case "$trans_state" in
        starting) status="启动中..."; status_icon="→" ;;
        stopping) status="停止中..."; status_icon="×" ;;
    esac

    # ===== 4. 拼装描述（模仿 Openlist_online：前一行带状态图标+IP+账号）=====
    local extra_line=""
    if [ "$status" = "运行中" ] || [ "$status" = "启动中..." ]; then
        extra_line="访问 http://${ip}:8888 账号admin/admin"
    else
        extra_line="访问 http://${ip}:8888 账号admin/admin"
    fi

    local new_desc="iQOO 7 专属宝塔面板自动安装+开机自启 Magisk 模块
首次安装自动检测宝塔：已装跳过/残留清理/未装联网安装
| ${status_icon} 状态: ${status}
| ${extra_line}
| 默认账号: admin  密码: admin
└ 管理: btpanel status   操作: 点右下按钮 音量±菜单"

    if [ -f "$module_prop" ]; then
        sed -i "/^description=/c\description=$new_desc" "$module_prop" 2>/dev/null
    fi
}

# ========== 主执行流程 ==========

# 等待启动完成
wait_for_boot_complete

# 首次检查：如果有残留目录（安装未完成留下的空壳），先清理
if ! is_btpanel_installed && has_btpanel_residue; then
    cleanup_btpanel_residue
fi

# 二次检查：是否已完整安装宝塔面板
if is_btpanel_installed; then
    # ✅ 已安装 → 跳过自动安装，直接启动服务
    mkdir -p "${BTPANEL_FLAG_DIR}"
    touch "${BTPANEL_FLAG_DIR}/installed"
    bt_bin=$(find_btpanel)
    if [ -n "$bt_bin" ]; then
        start_btpanel "$bt_bin"
    fi
else
    # ❌ 未安装 → 等待网络就绪后自动安装
    wait_for_network

    # 检查是否正在安装中（防止多实例冲突）
    if [ -f "$INSTALL_LOCK" ]; then
        :
    else
        # 启动自动安装（后台运行，日志落盘）
        auto_install_btpanel
    fi
fi

# 更新模块描述
update_module_desc

# 定期更新状态（每 5 分钟）
(
    while true; do
        sleep 300
        update_module_desc
    done
) &

exit 0