#!/system/bin/sh
#
# iQOO 7 宝塔面板开机自启服务脚本
# 自动安装 + 开机自启宝塔面板服务
# 适配 Alpha Magisk (3400) 热开关 / disable 标记 / 多路径 module.prop
#

MODDIR=${0%/*}
BTPANEL_BIN=""
BTPANEL_INSTALL_DIR="/data/btpanel"
BTPANEL_FLAG_DIR="${BTPANEL_INSTALL_DIR}/.module_flags"
BTPANEL_STATE_FILE="${BTPANEL_FLAG_DIR}/state"
INSTALL_LOCK="${BTPANEL_FLAG_DIR}/install.lock"
INSTALL_LOG="${BTPANEL_INSTALL_DIR}/install.log"
CRASH_LOG="${BTPANEL_INSTALL_DIR}/crash.log"
INSTALL_FAILED_LOG="${BTPANEL_FLAG_DIR}/install.failed.log"
# customize.sh 刷入阶段没装完 → service.sh 开机立刻强制续装
FORCE_CONTINUE_FLAG="${BTPANEL_FLAG_DIR}/force_continue_install"
# SH 解释器探测：Android recovery / Magisk 环境经常没有 bash，必须兼容 sh
if command -v bash >/dev/null 2>&1; then
    SH_BIN=$(command -v bash)
elif command -v sh >/dev/null 2>&1; then
    SH_BIN=$(command -v sh)
elif [ -x /system/bin/sh ]; then
    SH_BIN=/system/bin/sh
else
    SH_BIN=/bin/sh
fi
# 模块多路径兼容（Magisk 原版 / Alpha / Delta / Kitsune）
# 注意：busybox ash 不支持数组 → 用空格分隔字符串，路径无空格安全
MODULE_PATHS="/data/adb/modules/btpanel_iqoo7 /data/adb/modules_update/btpanel_iqoo7 /data/alcatel/modules/btpanel_iqoo7 /data/local/tmp/magisk_btpanel_iqoo7"

mkdir -p "${BTPANEL_FLAG_DIR}" 2>/dev/null || true

log_crash() {
    mkdir -p "$BTPANEL_FLAG_DIR" 2>/dev/null || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [service.sh] $1" >> "$CRASH_LOG" 2>/dev/null || true
}

# ========== 模块被禁用/热更时的安全退出 ==========
safe_cleanup_on_disable() {
    log_crash "safe_cleanup_on_disable: 模块被禁用/热更，安全清理后退出"

    # 停面板服务
    local bt_bin=$(find_btpanel)
    if [ -n "$bt_bin" ]; then
        export BT_IGNORE=1
        "$bt_bin" stop >/dev/null 2>&1 || true
    fi
    pkill -f "BT-Panel" >/dev/null 2>&1 || true
    pkill -f "gunicorn.*panel" >/dev/null 2>&1 || true

    # 杀掉 service.sh 启动的后台定期刷新进程 + 它的后代 sleep
    local self_pid=$$
    local p
    for p in $(pgrep -f "update_module_desc" 2>/dev/null); do
        [ -n "$p" ] && kill -9 "$p" 2>/dev/null || true
    done
    for p in $(pgrep -P "$self_pid" 2>/dev/null); do
        [ -n "$p" ] && kill -9 "$p" 2>/dev/null || true
    done

    rm -f "$BTPANEL_STATE_FILE" "$INSTALL_LOCK" 2>/dev/null || true
    exit 0
}

is_module_disabled() {
    local md
    for md in $MODULE_PATHS; do
        [ -f "$md/disable" ]    && return 0
        [ -f "$md/remove" ]     && return 0
        [ -f "$md/skip_mount" ] && return 0
    done
    return 1
}

# ========== 通用：启动/网络/安装检测 ==========

wait_for_boot_complete() {
    local timeout=60 elapsed=0
    while [ "$(getprop sys.boot_completed)" != "1" ]; do
        sleep 2; elapsed=$((elapsed + 2))
        [ $elapsed -ge $timeout ] && break
    done
    sleep 5
}

wait_for_network() {
    local timeout=120 elapsed=0
    while true; do
        ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 && break
        [ "$(getprop net.dns1 2>/dev/null)" != "" ] && break
        [ "$(getprop dhcp.wlan0.gateway 2>/dev/null)" != "" ] && break
        if [ -f /proc/net/route ]; then
            grep -q '^wlan0\|^eth0\|^rmnet' /proc/net/route 2>/dev/null && break
        fi
        sleep 5; elapsed=$((elapsed + 5))
        [ $elapsed -ge $timeout ] && break
    done
}

find_btpanel() {
    local p
    for p in /www/server/panel/bt /data/btpanel/bt /data/btpanel/server/panel/bt \
             /data/adb/btpanel/bt /data/btpanel/panel/bt /data/linux/bt \
             /data/linux/www/server/panel/bt /usr/bin/bt; do
        [ -f "$p" ] && [ -x "$p" ] && echo "$p" && return 0
    done
    local which_bt=$(command -v bt 2>/dev/null)
    [ -n "$which_bt" ] && [ -f "$which_bt" ] && echo "$which_bt" && return 0
    return 1
}

has_btpanel_residue() {
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

cleanup_btpanel_residue() {
    mkdir -p "${BTPANEL_INSTALL_DIR}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 清理残留目录" >> "${INSTALL_LOG}" 2>/dev/null || true
    local p
    for p in /www/server/panel/bt "${BTPANEL_INSTALL_DIR}/bt"; do
        [ -x "$p" ] && "$p" stop >/dev/null 2>&1
    done
    pkill -f "BT-Panel" >/dev/null 2>&1 || true
    pkill -f "gunicorn.*panel" >/dev/null 2>&1 || true
    rm -f "$INSTALL_LOCK" "${BTPANEL_FLAG_DIR}/installed"
    [ -d "/www/server/panel" ] && [ ! -f "/www/server/panel/class/panelPlugin.py" ] && \
        rm -rf /www/server/panel 2>/dev/null || true
    [ -d "${BTPANEL_INSTALL_DIR}/panel" ] && [ ! -f "${BTPANEL_INSTALL_DIR}/panel/class/panelPlugin.py" ] && \
        rm -rf "${BTPANEL_INSTALL_DIR}/panel" 2>/dev/null || true
}

is_btpanel_installed() {
    local bt_bin=$(find_btpanel)
    local core_ok=0
    local d
    for d in /www/server/panel /data/btpanel/server/panel "${BTPANEL_INSTALL_DIR}/panel" \
             /data/adb/btpanel/panel /data/linux/www/server/panel; do
        [ -d "$d" ] && [ -f "$d/class/panelPlugin.py" ] && core_ok=1 && break
    done
    [ -n "$bt_bin" ] && [ $core_ok -eq 1 ] && return 0
    return 1
}

download_file() {
    local url="$1" out="$2"
    # Android /tmp 通常不存在 → 用 /data/local/tmp
    local out_dir
    out_dir=$(dirname "$out" 2>/dev/null)
    [ -n "$out_dir" ] && mkdir -p "$out_dir" 2>/dev/null
    if command -v curl >/dev/null 2>&1; then
        curl -sSLo "$out" "$url" --connect-timeout 30 --retry 3
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$out" "$url" --timeout=30 --tries=3
    else
        return 1
    fi
}

# ========== /www 只读文件系统兼容 ==========
ensure_www_writable() {
    if [ -d /www ] && [ -w /www ]; then return 0; fi
    mkdir -p /www 2>/dev/null
    if [ -d /www ] && touch /www/.write_test 2>/dev/null; then
        rm -f /www/.write_test; return 0
    fi
    mount -o remount,rw / 2>/dev/null
    mkdir -p /www 2>/dev/null
    if [ -d /www ] && touch /www/.write_test 2>/dev/null; then
        rm -f /www/.write_test; return 0
    fi
    mkdir -p "${BTPANEL_INSTALL_DIR}/www_data" 2>/dev/null
    if [ -d /www ]; then
        mount --bind "${BTPANEL_INSTALL_DIR}/www_data" /www 2>/dev/null
        if [ -w /www ]; then return 0; fi
    fi
    return 1
}

patch_install_script_for_data() {
    local script="$1"
    [ ! -f "$script" ] && return 1
    sed -i 's|/www/server|/data/btpanel/server|g' "$script" 2>/dev/null
    sed -i 's|/www/wwwroot|/data/btpanel/wwwroot|g' "$script" 2>/dev/null
    sed -i 's|/www/backup|/data/btpanel/backup|g' "$script" 2>/dev/null
    sed -i 's|/www/wwwlogs|/data/btpanel/wwwlogs|g' "$script" 2>/dev/null
    sed -i 's|/usr/bin/bt|/data/btpanel/bt|g' "$script" 2>/dev/null
    sed -i 's|/usr/bin/python|/data/btpanel/server/python/bin/python|g' "$script" 2>/dev/null
    sed -i 's|/etc/init.d/bt|/data/btpanel/init.d/bt|g' "$script" 2>/dev/null
    mkdir -p /data/btpanel/server /data/btpanel/wwwroot /data/btpanel/bt 2>/dev/null
    return 0
}

setup_default_credentials() {
    sleep 3
    local bt_bin=$(find_btpanel)
    [ -z "$bt_bin" ] && return 1
    echo "admin" | "$bt_bin" 5 >/dev/null 2>&1
    echo "admin" | "$bt_bin" 6 >/dev/null 2>&1
    return 0
}

# 安装中写日志（所有 stdout/stderr 均落盘；失败保留现场）
auto_install_btpanel() {
    mkdir -p "${BTPANEL_FLAG_DIR}"
    echo "$$" > "$INSTALL_LOCK"

    # 日志轮转（512KB 截断保留末 1000 行）
    if [ -f "$INSTALL_LOG" ]; then
        local log_size=$(wc -c < "$INSTALL_LOG" 2>/dev/null || echo 0)
        if [ "$log_size" -gt 524288 ]; then
            tail -n 1000 "$INSTALL_LOG" > "${INSTALL_LOG}.tmp" 2>/dev/null \
                && mv "${INSTALL_LOG}.tmp" "$INSTALL_LOG"
        fi
    fi

    {
        echo "========== 自动安装开始 $(date '+%Y-%m-%d %H:%M:%S') =========="
        if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
            echo "[FATAL] 没有 curl 也没有 wget，无法联网下载"
            exit 1
        fi

        # ===== 关键：处理 /www 只读问题 =====
        if ensure_www_writable; then
            echo "[OK] /www 可写，使用标准路径"
        else
            echo "[WARN] /www 不可写，将 patch 安装脚本使用 /data/btpanel"
        fi

        echo "下载 install_panel.sh..."
        local install_script="/data/local/tmp/bt_install_panel.sh"
        if ! download_file "https://download.bt.cn/install/install_panel.sh" "$install_script"; then
            echo "[FATAL] 下载安装脚本失败"
            exit 2
        fi
        chmod 0755 "$install_script"

        # 如果 /www 不可写，patch 安装脚本使用 /data/btpanel
        if ! ensure_www_writable; then
            patch_install_script_for_data "$install_script"
            echo "[OK] 安装脚本已 patch: /www → /data/btpanel, /usr/bin/bt → /data/btpanel/bt"
        fi

        echo "执行安装（3-10 分钟）..."
        # 注意：本块已经 { ... } >> "$INSTALL_LOG" 2>&1 重定向，不需要 tee
        # 用 SH_BIN（可能是 bash 也可能是 sh）执行脚本，不用 PIPESTATUS
        echo "y" | "$SH_BIN" "$install_script" ed8484bec
        local rc=$?
        echo "安装脚本退出码: $rc"

        if is_btpanel_installed; then
            echo "[OK] 宝塔面板安装成功"
            setup_default_credentials
            touch "${BTPANEL_FLAG_DIR}/installed"
            local bt_bin=$(find_btpanel)
            if [ -n "$bt_bin" ]; then
                export BT_IGNORE=1
                nohup "$bt_bin" start >/dev/null 2>&1 &
            fi
        else
            echo "[FATAL] 安装失败（退出码 $rc），请查看上方日志"
        fi
    } >> "${INSTALL_LOG}" 2>&1

    local overall_rc=$?
    if [ $overall_rc -ne 0 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 安装流程异常，rc=$overall_rc" >> "$CRASH_LOG"
        cp -f "$INSTALL_LOG" "${BTPANEL_FLAG_DIR}/install.failed.log" 2>/dev/null || true
    fi

    # 成功则同时清除「force_continue」标志；失败保留让下次开机继续兜底
    if is_btpanel_installed; then
        rm -f "$FORCE_CONTINUE_FLAG"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] auto_install_btpanel: 安装成功，清除 force_continue_install 标志" >> "$INSTALL_LOG"
    fi

    rm -f "$INSTALL_LOCK"
    return $overall_rc
}

start_btpanel() {
    local bt_bin="$1"
    [ -z "$bt_bin" ] && return 1

    local pid_file="" f p
    for f in /www/server/panel/data/bt.pid /data/btpanel/bt.pid; do
        [ -f "$f" ] && pid_file="$f" && break
    done
    if [ -n "$pid_file" ]; then
        p=$(cat "$pid_file" 2>/dev/null)
        [ -n "$p" ] && kill -0 "$p" 2>/dev/null && return 0
    fi

    mkdir -p "$BTPANEL_FLAG_DIR"
    echo "starting" > "$BTPANEL_STATE_FILE"

    export BT_IGNORE=1
    nohup "$bt_bin" start >/dev/null 2>&1 &

    (
        local waited=0 started=0
        while [ $waited -lt 30 ]; do
            sleep 3; waited=$((waited + 3))
            started=0
            for f in /www/server/panel/data/bt.pid /data/btpanel/bt.pid; do
                [ -f "$f" ] || continue
                p=$(cat "$f" 2>/dev/null)
                [ -n "$p" ] && kill -0 "$p" 2>/dev/null && started=1 && break
            done
            [ $started -eq 1 ] && break
        done
        rm -f "$BTPANEL_STATE_FILE"
        update_module_desc
    ) &
    return 0
}

stop_btpanel() {
    local bt_bin="$1"
    [ -z "$bt_bin" ] && bt_bin=$(find_btpanel)
    [ -z "$bt_bin" ] && return 1

    mkdir -p "$BTPANEL_FLAG_DIR"
    echo "stopping" > "$BTPANEL_STATE_FILE"

    export BT_IGNORE=1
    "$bt_bin" stop >/dev/null 2>&1

    (
        local waited=0 running=0 f p
        while [ $waited -lt 20 ]; do
            sleep 2; waited=$((waited + 2))
            running=0
            for f in /www/server/panel/data/bt.pid /data/btpanel/bt.pid; do
                [ -f "$f" ] || continue
                p=$(cat "$f" 2>/dev/null)
                [ -n "$p" ] && kill -0 "$p" 2>/dev/null && running=1 && break
            done
            pgrep -f "BT-Panel" >/dev/null 2>&1 && running=1
            [ $running -eq 0 ] && break
        done
        pkill -f "BT-Panel" >/dev/null 2>&1 || true
        pkill -f "gunicorn.*panel" >/dev/null 2>&1 || true
        rm -f "$BTPANEL_STATE_FILE"
        update_module_desc
    ) &
    return 0
}

# ========== 更新模块介绍：只显示「已启动/已关闭」两种最终清晰状态 ==========
# 内部过渡状态（启动中/停止中/安装中）只写 BTPANEL_STATE_FILE，不显示到模块介绍，避免 UI 跳动
update_module_desc() {
    local ip=""
    ip=$(ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    [ -z "$ip" ] && ip=$(ip addr show eth0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    [ -z "$ip" ] && ip=$(getprop dhcp.wlan0.ipaddress 2>/dev/null)
    [ -z "$ip" ] && ip="---"

    # 最终只判断两种状态：是否实际在运行
    local running=0 installed=0
    local bt_bin=$(find_btpanel)
    [ -n "$bt_bin" ] && installed=1
    local f p
    for f in /www/server/panel/data/bt.pid /data/btpanel/bt.pid; do
        [ -f "$f" ] || continue
        p=$(cat "$f" 2>/dev/null)
        [ -n "$p" ] && kill -0 "$p" 2>/dev/null && running=1 && break
    done
    pgrep -f "BT-Panel" >/dev/null 2>&1 && running=1
    pgrep -f "gunicorn.*panel" >/dev/null 2>&1 && running=1

    # 状态优先级：安装中 ↓ > 安装失败 ✗ > 已启动 ▶ > 已关闭 ■
    local status="" icon=""
    if [ -f "$INSTALL_LOCK" ] || [ -f "$FORCE_CONTINUE_FLAG" ]; then
        # INSTALL_LOCK 存在 = 正在安装；FORCE_CONTINUE 存在 = 等待安装
        status="安装中 ↓"; icon="↓"
    elif ! is_btpanel_installed && [ -f "$INSTALL_FAILED_LOG" ]; then
        # 未安装 + 失败日志存在 = 安装失败
        status="安装失败 ✗"; icon="✗"
    elif [ $running -eq 1 ]; then
        status="已启动"; icon="▶"
    elif [ $installed -eq 1 ] || [ -f "${BTPANEL_FLAG_DIR}/installed" ]; then
        status="已关闭"; icon="■"
    else
        # 没装过也没失败过 = 等待安装中
        status="安装中 ↓"; icon="↓"
    fi

    local new_desc="iQOO 7 专属宝塔面板自动安装+开机自启 Magisk 模块
首次安装自动检测宝塔：已装跳过/残留清理/未装联网安装
状态: $icon $status
访问地址: http://${ip}:8888
默认账号: admin   密码: admin
操作: 点右下按钮  [音量上 = 开启宝塔]  [音量下 = 关闭宝塔]"

    local md mp
    for md in $MODULE_PATHS; do
        mp="$md/module.prop"
        [ -f "$mp" ] || continue
        sed -i "/^description=/c\description=$new_desc" "$mp" 2>/dev/null || true
    done
}

# ========== 主执行流程 ==========

is_module_disabled && log_crash "启动时检测到 disable/remove/skip_mount，跳过" && exit 0

wait_for_boot_complete

# 热开关二次检查（关模块立刻安全退出停服务）
is_module_disabled && safe_cleanup_on_disable

# 判定是否有「刷入阶段未装完，强制续装」标志 → 优先级最高，覆盖 is_btpanel_installed 判断
need_force_continue=0
[ -f "$FORCE_CONTINUE_FLAG" ] && need_force_continue=1

# 首次清理残留
if [ $need_force_continue -eq 1 ] || { ! is_btpanel_installed && has_btpanel_residue; }; then
    cleanup_btpanel_residue
fi

# 热开关三次检查（避免清理期间被禁用）
is_module_disabled && safe_cleanup_on_disable

bt_bin=""
if [ $need_force_continue -eq 1 ]; then
    # 最高优先级：customize.sh 明确说装到一半，立即联网续装
    log_crash "检测到 force_continue_install 标志 → 立即开始续装宝塔面板"
    wait_for_network
    is_module_disabled && safe_cleanup_on_disable
    if [ ! -f "$INSTALL_LOCK" ]; then
        ( auto_install_btpanel ) &
    fi
elif is_btpanel_installed; then
    mkdir -p "${BTPANEL_FLAG_DIR}"
    touch "${BTPANEL_FLAG_DIR}/installed"
    rm -f "$FORCE_CONTINUE_FLAG"  # 正常安装 → 保险清标志
    bt_bin=$(find_btpanel)
    [ -n "$bt_bin" ] && start_btpanel "$bt_bin"
else
    wait_for_network
    is_module_disabled && safe_cleanup_on_disable
    if [ ! -f "$INSTALL_LOCK" ]; then
        # 安装放在后台，避免阻塞后续开机流程；安装日志全部落盘 + 失败写 crash
        ( auto_install_btpanel ) &
    fi
fi

update_module_desc

# 定期刷新状态（每 5 分钟，每次刷新前检查 disable，关模块立刻退出）
(
    while true; do
        sleep 300
        is_module_disabled && safe_cleanup_on_disable
        update_module_desc
    done
) &

exit 0
