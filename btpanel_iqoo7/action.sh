#!/system/bin/sh
#
# iQOO 7 宝塔面板开机自启模块 - 操作菜单脚本
# 由 Magisk 模块「操作」按钮触发
# 操作方式：音量上 = 切换选择 | 音量下 = 确认选中
#

MODDIR=${0%/*}
BTPANEL_INSTALL_DIR="/data/btpanel"
BTPANEL_FLAG_DIR="${BTPANEL_INSTALL_DIR}/.module_flags"
BTPANEL_STATE_FILE="${BTPANEL_FLAG_DIR}/state"
INSTALL_LOG="${BTPANEL_INSTALL_DIR}/install.log"

mkdir -p "${BTPANEL_FLAG_DIR}"

# 颜色（Magisk 一般不解析 ANSI，尽量用符号）
GREEN="✔"
RED="✘"
CYAN="›"
YELLOW="●"

# ========== 复用函数：查找 / 检测 / 启停 ==========

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
    return 1
}

is_btpanel_installed() {
    local bt_bin=$(find_btpanel)
    local core_ok=0
    for d in /www/server/panel "${BTPANEL_INSTALL_DIR}/panel" /data/adb/btpanel/panel /data/linux/www/server/panel; do
        if [ -d "$d" ] && [ -f "$d/class/panelPlugin.py" ]; then core_ok=1; break; fi
    done
    [ -n "$bt_bin" ] && [ $core_ok -eq 1 ] && return 0
    return 1
}

# 启动（与 service.sh 保持一致：写状态文件 + 等启动 + 更新描述）
do_start_btpanel() {
    local bt_bin=$(find_btpanel)
    [ -z "$bt_bin" ] && echo "  找不到 bt 可执行文件" && return 1
    if is_btpanel_running; then echo "  已在运行中，无需启动"; return 0; fi
    echo "starting" > "${BTPANEL_STATE_FILE}"
    update_visible_desc
    export BT_IGNORE=1
    nohup "$bt_bin" start >/dev/null 2>&1 &
    local waited=0
    while [ $waited -lt 30 ]; do
        sleep 2
        waited=$((waited + 2))
        if is_btpanel_running; then break; fi
    done
    rm -f "${BTPANEL_STATE_FILE}"
    update_visible_desc
    if is_btpanel_running; then
        echo "  ${GREEN} 宝塔面板启动成功"
    else
        echo "  ${RED} 宝塔面板启动失败，请检查日志 ${INSTALL_LOG}"
    fi
    return 0
}

# 停止（与 service.sh 保持一致：写状态文件 + 等停止 + 更新描述）
do_stop_btpanel() {
    local bt_bin=$(find_btpanel)
    [ -z "$bt_bin" ] && echo "  找不到 bt 可执行文件" && return 1
    if ! is_btpanel_running; then echo "  已经是停止状态"; return 0; fi
    echo "stopping" > "${BTPANEL_STATE_FILE}"
    update_visible_desc
    export BT_IGNORE=1
    "$bt_bin" stop >/dev/null 2>&1
    local waited=0
    while [ $waited -lt 20 ]; do
        sleep 2
        waited=$((waited + 2))
        if ! is_btpanel_running; then break; fi
    done
    pkill -f "BT-Panel" >/dev/null 2>&1 || true
    pkill -f "gunicorn.*panel" >/dev/null 2>&1 || true
    rm -f "${BTPANEL_STATE_FILE}"
    update_visible_desc
    if ! is_btpanel_running; then
        echo "  ${GREEN} 宝塔面板已停止"
    else
        echo "  ${RED} 宝塔面板停止失败"
    fi
    return 0
}

# 获取当前面板访问地址（IP）
get_lan_ip() {
    local ip
    ip=$(ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    [ -z "$ip" ] && ip=$(ip addr show eth0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    [ -z "$ip" ] && ip=$(getprop dhcp.wlan0.ipaddress 2>/dev/null)
    [ -z "$ip" ] && ip="---"
    echo "$ip"
}

# 立即更新 Magisk 模块可见描述（action.sh 是独立脚本，所以内联一份简化版）
update_visible_desc() {
    local module_dir="/data/adb/modules/btpanel_iqoo7"
    local module_prop="$module_dir/module.prop"
    [ ! -f "$module_prop" ] && return

    local ip=$(get_lan_ip)
    local trans_state=""
    [ -f "$BTPANEL_STATE_FILE" ] && trans_state=$(cat "$BTPANEL_STATE_FILE" 2>/dev/null)

    local status="未安装" icon="✘"
    local bt_bin=$(find_btpanel)
    if [ -n "$bt_bin" ]; then
        if is_btpanel_running; then status="运行中"; icon="✔"
        else status="已停止"; icon="✘"; fi
    elif [ -f "${BTPANEL_FLAG_DIR}/installed" ]; then status="安装完成"; icon="●"
    elif [ -f "${BTPANEL_FLAG_DIR}/install.lock" ]; then status="安装中..."; icon="↓"
    fi
    case "$trans_state" in
        starting) status="启动中..."; icon="→" ;;
        stopping) status="停止中..."; icon="×" ;;
    esac

    local desc="iQOO 7 专属宝塔面板自动安装+开机自启 Magisk 模块
首次安装自动检测宝塔：已装跳过/残留清理/未装联网安装
| ${icon} 状态: ${status}
| 访问 http://${ip}:8888 账号admin/admin
| 默认账号: admin  密码: admin
└ 管理: btpanel status   操作: 点右下按钮 音量±菜单"

    sed -i "/^description=/c\description=$desc" "$module_prop" 2>/dev/null || true
}

# ========== 音量键读取（核心）==========
# 方法优先级：1) Magisk keycheck  2) getevent  3) 兜底（超时自动）
# 每次调用返回："UP" / "DOWN" / "BACK" / "TIMEOUT"

# 尝试定位输入事件节点
find_volume_input_dev() {
    # 优先用 getevent -lp 找到包含 VOLUME 的设备
    local dev
    dev=$(getevent -lp 2>/dev/null | grep -B1 "VOLUMEUP\|VOLUMEDOWN" | grep 'add device' | head -n1 | sed 's/.*name: //' 2>/dev/null)
    if [ -z "$dev" ]; then
        for d in /dev/input/event*; do
            if getevent -lp "$d" 2>/dev/null | grep -q "VOLUMEUP\|VOLUMEDOWN"; then
                echo "$d"
                return 0
            fi
        done
    else
        echo "/dev/input/$dev"
        return 0
    fi
    return 1
}

read_volume_key() {
    # 等待下一次按键（最长 60 秒超时）
    local timeout_sec=${1:-60}

    # 尝试 keycheck 工具（部分 Magisk 版本自带）
    if [ -x "/data/adb/keycheck" ] || [ -x "/sbin/.magisk/busybox/keycheck" ] || command -v keycheck >/dev/null 2>&1; then
        local kc_bin=""
        [ -x "/data/adb/keycheck" ] && kc_bin="/data/adb/keycheck"
        [ -z "$kc_bin" ] && [ -x "/sbin/.magisk/busybox/keycheck" ] && kc_bin="/sbin/.magisk/busybox/keycheck"
        [ -z "$kc_bin" ] && kc_bin="keycheck"
        # 常见 keycheck 返回：115=VOL+ 114=VOL- 4=BACK
        local code
        code=$("$kc_bin" 2>/dev/null)
        case "$code" in
            115|113|1) echo "UP"; return 0 ;;
            114|116|2) echo "DOWN"; return 0 ;;
            4|0)     echo "BACK"; return 0 ;;
        esac
    fi

    # 回退：getevent 读取事件（超时用 timeout 工具或 shell alarm）
    local event_dev=$(find_volume_input_dev)
    if [ -n "$event_dev" ] && command -v timeout >/dev/null 2>&1; then
        local ev_line
        ev_line=$(timeout ${timeout_sec} getevent -lc 1 "$event_dev" 2>/dev/null | grep "KEY_VOLUME")
        if echo "$ev_line" | grep -q "KEY_VOLUMEUP";      then echo "UP";   return 0; fi
        if echo "$ev_line" | grep -q "KEY_VOLUMEDOWN";    then echo "DOWN"; return 0; fi
    fi

    # 再兜底：/proc 轮询（部分设备会暴露节点）
    local waited=0
    while [ $waited -lt $timeout_sec ]; do
        if [ -r "/sys/class/input/key/vol_up" ] 2>/dev/null; then
            local v=$(cat /sys/class/input/key/vol_up 2>/dev/null)
            [ "$v" = "1" ] && echo "UP" && return 0
        fi
        if [ -r "/sys/class/input/key/vol_down" ] 2>/dev/null; then
            local v=$(cat /sys/class/input/key/vol_down 2>/dev/null)
            [ "$v" = "1" ] && echo "DOWN" && return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    echo "TIMEOUT"
    return 1
}

# ========== 菜单渲染 ==========
# 参数：当前选中项索引(从0开始)
render_menu() {
    local sel=$1
    local running=$2
    local ip=$(get_lan_ip)

    echo ""
    echo "========================================================"
    echo "  iQOO 7 宝塔面板 Magisk 模块 · 操作菜单"
    echo "========================================================"
    echo "  面板状态: $(if [ "$running" -eq 1 ]; then echo "${GREEN} 运行中"; else echo "${RED} 已停止"; fi)"
    echo "  访问地址: http://${ip}:8888"
    echo "  账  号  : admin   密 码  : admin"
    echo "--------------------------------------------------------"
    echo "  操作: 音量上 = 移动选择 | 音量下 = 确认选中"
    echo "--------------------------------------------------------"

    local i=0
    for opt in "${MENU_ITEMS[@]}"; do
        local mark=" "
        [ $i -eq $sel ] && mark="${CYAN}"
        echo "    [${mark}] $opt"
        i=$((i + 1))
    done
    echo "--------------------------------------------------------"
    echo "  提示：面板停止时默认选中「开启宝塔」，运行中默认选中「关闭宝塔」"
    echo ""
}

# ========== 主流程 ==========

echo "========================================================"
echo "  iQOO 7 宝塔面板 Magisk 模块 · 操作菜单初始化"
echo "========================================================"
echo "  正在初始化菜单... (准备好后按音量键开始选择)"

# 确认基础文件
if ! is_btpanel_installed; then
    echo ""
    echo "  ${RED} 未检测到宝塔面板完整安装。"
    echo "  请先重启设备（联网后会自动安装 3-10 分钟）"
    echo "  或者在 shell 中执行: btpanel install"
    echo ""
    sleep 5
    exit 0
fi

# 菜单选项（依据状态动态决定第一个选项位置）
# 定义后按 [选中项] 切换
MENU_OPEN="开启宝塔面板"
MENU_CLOSE="关闭宝塔面板"
MENU_RESTART="重启宝塔面板"
MENU_URL="显示访问地址/登录信息"
MENU_EXIT="退出菜单"

# 根据当前状态确定菜单顺序（第一个为默认选中）
RUNNING_NOW=0
is_btpanel_running && RUNNING_NOW=1

if [ $RUNNING_NOW -eq 1 ]; then
    # 已开启 → 菜单从关闭开始
    MENU_ITEMS=("$MENU_CLOSE" "$MENU_RESTART" "$MENU_URL" "$MENU_EXIT")
else
    # 已关闭 → 菜单从开启开始
    MENU_ITEMS=("$MENU_OPEN" "$MENU_RESTART" "$MENU_URL" "$MENU_EXIT")
fi

SELECTED=0
TOTAL=${#MENU_ITEMS[@]}

# 首次渲染
echo -en "\033[2J" >/dev/null 2>&1 || true   # 尝试清屏（不行就算了）
render_menu $SELECTED $RUNNING_NOW

# 主循环
while true; do
    key=$(read_volume_key 90)
    case "$key" in
        UP)
            # 上键：切换选中（向下移动）
            SELECTED=$(( (SELECTED + 1) % TOTAL ))
            render_menu $SELECTED $RUNNING_NOW
            ;;
        DOWN)
            # 下键：确认
            choice="${MENU_ITEMS[$SELECTED]}"
            echo ""
            echo "  ${YELLOW} 执行: $choice"
            echo ""

            case "$choice" in
                "$MENU_OPEN")
                    echo "  正在开启宝塔面板..."
                    do_start_btpanel
                    # 执行完刷新状态后回到菜单（更新 RUNNING_NOW + 重新排序）
                    sleep 2
                    is_btpanel_running && RUNNING_NOW=1 || RUNNING_NOW=0
                    if [ $RUNNING_NOW -eq 1 ]; then
                        MENU_ITEMS=("$MENU_CLOSE" "$MENU_RESTART" "$MENU_URL" "$MENU_EXIT")
                    else
                        MENU_ITEMS=("$MENU_OPEN" "$MENU_RESTART" "$MENU_URL" "$MENU_EXIT")
                    fi
                    TOTAL=${#MENU_ITEMS[@]}
                    SELECTED=0
                    render_menu $SELECTED $RUNNING_NOW
                    ;;
                "$MENU_CLOSE")
                    echo "  正在关闭宝塔面板..."
                    do_stop_btpanel
                    sleep 2
                    is_btpanel_running && RUNNING_NOW=1 || RUNNING_NOW=0
                    if [ $RUNNING_NOW -eq 1 ]; then
                        MENU_ITEMS=("$MENU_CLOSE" "$MENU_RESTART" "$MENU_URL" "$MENU_EXIT")
                    else
                        MENU_ITEMS=("$MENU_OPEN" "$MENU_RESTART" "$MENU_URL" "$MENU_EXIT")
                    fi
                    TOTAL=${#MENU_ITEMS[@]}
                    SELECTED=0
                    render_menu $SELECTED $RUNNING_NOW
                    ;;
                "$MENU_RESTART")
                    echo "  重启宝塔面板..."
                    do_stop_btpanel
                    sleep 3
                    do_start_btpanel
                    sleep 2
                    is_btpanel_running && RUNNING_NOW=1 || RUNNING_NOW=0
                    if [ $RUNNING_NOW -eq 1 ]; then
                        MENU_ITEMS=("$MENU_CLOSE" "$MENU_RESTART" "$MENU_URL" "$MENU_EXIT")
                    else
                        MENU_ITEMS=("$MENU_OPEN" "$MENU_RESTART" "$MENU_URL" "$MENU_EXIT")
                    fi
                    TOTAL=${#MENU_ITEMS[@]}
                    SELECTED=0
                    render_menu $SELECTED $RUNNING_NOW
                    ;;
                "$MENU_URL")
                    echo "  =============================================="
                    echo "    面板地址: http://$(get_lan_ip):8888"
                    echo "    账    号: admin"
                    echo "    密    码: admin"
                    echo "  =============================================="
                    echo ""
                    echo "  按任意音量键返回菜单..."
                    read_volume_key 30 >/dev/null
                    render_menu $SELECTED $RUNNING_NOW
                    ;;
                "$MENU_EXIT")
                    echo ""
                    echo "  ${GREEN} 已退出操作菜单，模块保持开机自启。"
                    echo ""
                    update_visible_desc
                    exit 0
                    ;;
            esac
            ;;
        BACK)
            echo ""
            echo "  已退出操作菜单。"
            update_visible_desc
            exit 0
            ;;
        TIMEOUT)
            echo ""
            echo "  90 秒无操作，自动退出菜单。"
            update_visible_desc
            exit 0
            ;;
    esac
done

exit 0
