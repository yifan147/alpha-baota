#!/system/bin/sh
#
# iQOO 7 宝塔面板开机自启模块 - 操作脚本
# 适配 Alpha Magisk (3400) 及主流 Magisk 分支
# 操作方式：音量上 = 直接开启宝塔 | 音量下 = 直接关闭宝塔
# 无需选择菜单，一按即切换，按电源键退出。
#

MODDIR=${0%/*}
BTPANEL_INSTALL_DIR="/data/btpanel"
BTPANEL_FLAG_DIR="${BTPANEL_INSTALL_DIR}/.module_flags"
BTPANEL_STATE_FILE="${BTPANEL_FLAG_DIR}/state"
INSTALL_LOG="${BTPANEL_INSTALL_DIR}/install.log"
CRASH_LOG="${BTPANEL_INSTALL_DIR}/crash.log"
INSTALL_FAILED_LOG="${BTPANEL_FLAG_DIR}/install.failed.log"
FORCE_CONTINUE_FLAG="${BTPANEL_FLAG_DIR}/force_continue_install"
INSTALL_LOCK="${BTPANEL_FLAG_DIR}/install.lock"
MODULE_DIRS="/data/adb/modules/btpanel_iqoo7 /data/adb/modules_update/btpanel_iqoo7 /data/alcatel/modules/btpanel_iqoo7 /data/local/tmp/magisk_btpanel_iqoo7"

mkdir -p "${BTPANEL_FLAG_DIR}" 2>/dev/null || true

# 共享函数（与 service.sh / btpanel 语义一致，保持独立不互调）
find_btpanel() {
    local paths="
        /www/server/panel/bt
        /data/btpanel/bt
        /data/btpanel/server/panel/bt
        /data/adb/btpanel/bt
        /data/btpanel/panel/bt
        /data/linux/bt
        /data/linux/www/server/panel/bt
        /usr/bin/bt
    "
    for p in $paths; do
        if [ -f "$p" ] && [ -x "$p" ]; then echo "$p"; return 0; fi
    done
    local which_bt=$(command -v bt 2>/dev/null)
    if [ -n "$which_bt" ] && [ -f "$which_bt" ]; then echo "$which_bt"; return 0; fi
    return 1
}

is_btpanel_running() {
    for f in /www/server/panel/data/bt.pid /data/btpanel/bt.pid; do
        if [ -f "$f" ]; then
            local p=$(cat "$f" 2>/dev/null)
            if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then return 0; fi
        fi
    done
    pgrep -f "BT-Panel" >/dev/null 2>&1 && return 0
    pgrep -f "gunicorn.*panel" >/dev/null 2>&1 && return 0
    return 1
}

is_btpanel_installed() {
    local bt_bin=$(find_btpanel)
    local core_ok=0
    for d in /www/server/panel /data/btpanel/server/panel "${BTPANEL_INSTALL_DIR}/panel" /data/adb/btpanel/panel /data/linux/www/server/panel; do
        if [ -d "$d" ] && [ -f "$d/class/panelPlugin.py" ]; then core_ok=1; break; fi
    done
    [ -n "$bt_bin" ] && [ $core_ok -eq 1 ] && return 0
    return 1
}

get_lan_ip() {
    local ip
    ip=$(ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    [ -z "$ip" ] && ip=$(ip addr show eth0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    [ -z "$ip" ] && ip=$(getprop dhcp.wlan0.ipaddress 2>/dev/null)
    [ -z "$ip" ] && ip="---"
    echo "$ip"
}

# 写 crash 日志
log_crash() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [action.sh] $1" >> "$CRASH_LOG" 2>/dev/null || true
}

# 更新模块介绍（Alpha/Delta/Magisk 标准路径都覆盖）
update_visible_desc() {
    local ip=$(get_lan_ip)
    local status="" icon=""
    # 状态优先级（与 service.sh 对齐）：安装中 ↓ > 安装失败 ✗ > 已启动 ▶ > 已关闭 ■
    if [ -f "$INSTALL_LOCK" ] || [ -f "$FORCE_CONTINUE_FLAG" ]; then
        status="安装中 ↓"; icon="↓"
    elif ! is_btpanel_installed && [ -f "$INSTALL_FAILED_LOG" ]; then
        status="安装失败 ✗"; icon="✗"
    elif is_btpanel_running; then
        status="已启动"; icon="▶"
    elif is_btpanel_installed || [ -f "${BTPANEL_FLAG_DIR}/installed" ]; then
        status="已关闭"; icon="■"
    else
        status="安装中 ↓"; icon="↓"
    fi

    local desc="iQOO 7 专属宝塔面板自动安装+开机自启 Magisk 模块
首次安装自动检测宝塔：已装跳过/残留清理/未装联网安装
状态: $icon $status
访问地址: http://${ip}:8888
默认账号: admin  密码: admin
操作: 点右下按钮  [音量上 = 开启]  [音量下 = 关闭]"

    for md in $MODULE_DIRS; do
        local mp="$md/module.prop"
        [ -f "$mp" ] || continue
        local descfile="${BTPANEL_FLAG_DIR}/.action_desc_$$"
        local tmpfile="${BTPANEL_FLAG_DIR}/.action_newprop_$$"
        printf '%s' "$desc" > "$descfile" 2>/dev/null

        # 100% 精准方案：只保留合法 key=value 行（key 不是 description），再追加新 description
        rm -f "$tmpfile"
        grep -E '^(id|name|version|versionCode|author)=' "$mp" > "$tmpfile" 2>/dev/null || true
        if [ ! -s "$tmpfile" ]; then
            grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$mp" | grep -v '^description=' > "$tmpfile" 2>/dev/null || true
            [ ! -s "$tmpfile" ] && cat "$mp" > "$tmpfile" 2>/dev/null
        fi
        if [ -f "$descfile" ]; then
            local first=1 dline
            while IFS= read -r dline || [ -n "$dline" ]; do
                if [ $first -eq 1 ]; then
                    printf 'description=%s\n' "$dline" >> "$tmpfile" 2>/dev/null
                    first=0
                else
                    printf '%s\n' "$dline" >> "$tmpfile" 2>/dev/null
                fi
            done < "$descfile"
            if [ $first -eq 1 ]; then
                printf 'description=btpanel_iqoo7\n' >> "$tmpfile" 2>/dev/null
            fi
        fi

        if [ -s "$tmpfile" ]; then
            mv "$tmpfile" "$mp" 2>/dev/null || true
            chmod 0644 "$mp" 2>/dev/null || true
        fi
        rm -f "$tmpfile" "$descfile" 2>/dev/null || true
    done
}

# ===== 启动 / 停止（写状态 + 同步更新介绍，失败自动落 crash log）=====
do_start() {
    local bt_bin=$(find_btpanel)
    if [ -z "$bt_bin" ]; then
        echo "  ❌ 未找到宝塔面板安装，请先安装（btpanel install）"
        log_crash "do_start: bt_bin 找不到"
        return 1
    fi
    if is_btpanel_running; then
        echo "  ℹ  宝塔面板已在运行中"
        return 0
    fi
    echo ""
    echo "  ▶ 正在启动宝塔面板..."
    mkdir -p "$BTPANEL_FLAG_DIR"
    echo "starting" > "$BTPANEL_STATE_FILE"
    update_visible_desc

    local ok=0
    export BT_IGNORE=1
    nohup "$bt_bin" start >/dev/null 2>&1 &
    # 等启动完成（30s 超时）
    local waited=0
    while [ $waited -lt 30 ]; do
        sleep 2
        waited=$((waited + 2))
        if is_btpanel_running; then ok=1; break; fi
    done
    rm -f "$BTPANEL_STATE_FILE"
    update_visible_desc
    if [ $ok -eq 1 ]; then
        echo "  ✅ 宝塔面板已启动"
        echo "     地址: http://$(get_lan_ip):8888   账号: admin   密码: admin"
        return 0
    else
        echo "  ❌ 启动失败，详情: $INSTALL_LOG"
        log_crash "do_start: 30s 内未检测到运行进程"
        return 1
    fi
}

do_stop() {
    local bt_bin=$(find_btpanel)
    if [ -z "$bt_bin" ]; then
        echo "  ❌ 未找到宝塔面板"
        log_crash "do_stop: bt_bin 找不到"
        return 1
    fi
    if ! is_btpanel_running; then
        echo "  ℹ  宝塔面板已是停止状态"
        return 0
    fi
    echo ""
    echo "  ■ 正在关闭宝塔面板..."
    mkdir -p "$BTPANEL_FLAG_DIR"
    echo "stopping" > "$BTPANEL_STATE_FILE"
    update_visible_desc

    export BT_IGNORE=1
    "$bt_bin" stop >/dev/null 2>&1 || true
    # 兜底强制杀
    sleep 2
    pkill -f "BT-Panel" >/dev/null 2>&1 || true
    pkill -f "gunicorn.*panel" >/dev/null 2>&1 || true
    sleep 1
    pkill -9 -f "BT-Panel" >/dev/null 2>&1 || true

    local ok=1
    is_btpanel_running && ok=0
    rm -f "$BTPANEL_STATE_FILE"
    update_visible_desc
    if [ $ok -eq 1 ]; then
        echo "  ✅ 宝塔面板已关闭"
        return 0
    else
        echo "  ⚠ 关闭命令已执行，但仍有残留进程（下次启动会自动清理）"
        log_crash "do_stop: 停止后仍有残留进程"
        return 1
    fi
}

# ===== Alpha Magisk (3400) 兼容的音量键读取 =====
# 优先级：
#  1) /data/adb/keycheck / /sbin/keycheck 等 keycheck 二进制
#  2) getevent 直接抓 KEY_VOLUMEUP / KEY_VOLUMEDOWN / KEY_POWER
#  3) input 节点轮询兜底
# 返回: "UP" / "DOWN" / "POWER" / "TIMEOUT"

find_vol_input() {
    local d
    for d in /dev/input/event*; do
        [ -r "$d" ] || continue
        if getevent -lp "$d" 2>/dev/null | grep -q "KEY_VOLUMEUP\|KEY_VOLUMEDOWN"; then
            echo "$d"
            return 0
        fi
    done
    # getevent -lp 全部输出里找（包含设备名）
    local all=$(getevent -lp 2>/dev/null)
    local dev=$(echo "$all" | grep -B1 "KEY_VOLUMEUP\|KEY_VOLUMEDOWN" | grep -oE "/dev/input/event[0-9]+" | head -n1)
    if [ -n "$dev" ]; then echo "$dev"; return 0; fi
    return 1
}

keycheck_try_paths() {
    # Alpha Magisk (3400) 常用 keycheck 位置
    for kc in \
        "/data/adb/keycheck" \
        "/sbin/keycheck" \
        "/sbin/.magisk/busybox/keycheck" \
        "/debug_ramdisk/keycheck" \
        "/data/adb/magisk/keycheck" \
        "/data/local/tmp/keycheck"; do
        [ -x "$kc" ] && echo "$kc" && return 0
    done
    local which=$(command -v keycheck 2>/dev/null)
    [ -n "$which" ] && echo "$which" && return 0
    return 1
}

read_key() {
    local timeout_sec=${1:-60}

    # ===== 方法 1：keycheck（Alpha Magisk 3400 首选）=====
    local kc_bin=$(keycheck_try_paths)
    if [ -n "$kc_bin" ]; then
        # keycheck 在 Alpha Magisk 返回约定：
        #   4 / 0 = 电源 / 退出键
        #   1 / 113 / 115 = VOL UP
        #   2 / 114 / 116 = VOL DOWN
        # 注意：必须用 timeout 包裹，否则 keycheck 可能无限阻塞不返回
        local timeout_bin="timeout"
        command -v "$timeout_bin" >/dev/null 2>&1 || timeout_bin=""
        local code rc
        if [ -n "$timeout_bin" ]; then
            code=$("$timeout_bin" "$timeout_sec" "$kc_bin" 2>/dev/null)
            rc=$?
            # timeout 返回 124 = 超时 → 直接走下一个方法
            [ "$rc" = "124" ] && code=""
        else
            # 无 timeout 命令 → 保守不调用（怕阻塞），直接走 getevent
            code=""
            rc=1
        fi
        # keycheck 某些实现用退出码代替 stdout
        [ -z "$code" ] && [ "$rc" != "124" ] && code=$rc
        case "$code" in
            115|113|1|UP|up)          echo "UP";    return 0 ;;
            114|116|2|DOWN|down)      echo "DOWN";  return 0 ;;
            4|0|PWR|power|POWER)      echo "POWER"; return 0 ;;
        esac
    fi

    # ===== 方法 2：getevent 原始事件（最通用）=====
    local evdev=$(find_vol_input)
    if [ -n "$evdev" ] && command -v getevent >/dev/null 2>&1; then
        # 用 timeout（Android toybox 带）
        local timeout_bin="timeout"
        command -v "$timeout_bin" >/dev/null 2>&1 || timeout_bin=""
        if [ -n "$timeout_bin" ]; then
            local raw_line
            raw_line=$("$timeout_bin" "$timeout_sec" getevent -lc 3 "$evdev" 2>/dev/null)
            if echo "$raw_line" | grep -qE "KEY_VOLUMEUP[[:space:]]+,[[:space:]]+DOWN|KEY_VOLUMEUP[[:space:]]+1"; then echo "UP"; return 0; fi
            if echo "$raw_line" | grep -qE "KEY_VOLUMEDOWN[[:space:]]+,[[:space:]]+DOWN|KEY_VOLUMEDOWN[[:space:]]+1"; then echo "DOWN"; return 0; fi
            if echo "$raw_line" | grep -qE "KEY_POWER[[:space:]]+,[[:space:]]+DOWN|KEY_POWER[[:space:]]+1"; then echo "POWER"; return 0; fi
        else
            # 无 timeout 命令，15s 短时间尝试
            local waited=0
            while [ $waited -lt $timeout_sec ]; do
                raw_line=$(getevent -lc 1 "$evdev" 2>/dev/null &
                    local pid=$!; sleep 1; kill $pid 2>/dev/null; wait 2>/dev/null)
                if echo "$raw_line" | grep -q "KEY_VOLUMEUP"; then echo "UP"; return 0; fi
                if echo "$raw_line" | grep -q "KEY_VOLUMEDOWN"; then echo "DOWN"; return 0; fi
                if echo "$raw_line" | grep -q "KEY_POWER"; then echo "POWER"; return 0; fi
                waited=$((waited + 2))
            done
        fi
    fi

    # ===== 方法 3：/sys /dev 轮询兜底 =====
    local waited=0
    while [ $waited -lt $timeout_sec ]; do
        for p in \
            /sys/class/input/key/vol_up \
            /sys/class/input/key/volume_up \
            /sys/class/sec/key/vol_up \
            /proc/volume_up; do
            [ -r "$p" ] || continue
            local v=$(cat "$p" 2>/dev/null)
            [ "$v" = "1" ] && echo "UP" && return 0
        done
        for p in \
            /sys/class/input/key/vol_down \
            /sys/class/input/key/volume_down \
            /sys/class/sec/key/vol_down \
            /proc/volume_down; do
            [ -r "$p" ] || continue
            local v=$(cat "$p" 2>/dev/null)
            [ "$v" = "1" ] && echo "DOWN" && return 0
        done
        sleep 1
        waited=$((waited + 1))
    done

    echo "TIMEOUT"
    return 1
}

# ========== 主流程 ==========

echo ""
echo "=========================================================="
echo "  iQOO 7 宝塔面板 · Alpha Magisk (3400) 操作面板"
echo "=========================================================="
echo ""
echo "  [音量上]  = 直接开启宝塔"
echo "  [音量下]  = 直接关闭宝塔"
echo "  [电源键]  = 退出操作菜单"
echo "  60 秒无操作自动退出"
echo ""

# 未安装直接提示退出
if ! is_btpanel_installed; then
    echo "  ❌ 未检测到宝塔面板完整安装。"
    echo "     本模块会在刷入时自动尝试安装宝塔面板。"
    echo "     若安装未完成，请联网后执行: btpanel install"
    echo "     日志: $INSTALL_LOG"
    sleep 6
    exit 0
fi

# 首次状态展示
local_ip=$(get_lan_ip)
if is_btpanel_running; then
    echo "  当前状态: ▶ 已启动    地址: http://${local_ip}:8888"
else
    echo "  当前状态: ■ 已关闭"
fi
echo ""
echo "  请按音量键执行操作..."
echo ""

update_visible_desc

while true; do
    key=$(read_key 60)
    case "$key" in
        UP)
            do_start
            echo ""
            echo "  继续按音量键操作，或按电源键/等待自动退出..."
            ;;
        DOWN)
            do_stop
            echo ""
            echo "  继续按音量键操作，或按电源键/等待自动退出..."
            ;;
        POWER)
            echo ""
            echo "  已退出。"
            update_visible_desc
            exit 0
            ;;
        TIMEOUT)
            echo ""
            echo "  60 秒无操作，自动退出。"
            update_visible_desc
            exit 0
            ;;
    esac
done

exit 0
