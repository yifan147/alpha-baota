#!/system/bin/sh
#
# iQOO 7 宝塔面板开机自启模块 - 安装脚本（customize.sh）
# 适配 Alpha Magisk (3400)
#
# 行为：
#  1) 先检测已安装 / 残留 / 未安装
#  2) 未安装时：若刷入环境有网络，立刻同步尝试安装宝塔（最长等 8 分钟，没装完写标志让开机阶段强制续装）
#  3) 安装失败一定写 install.log + crash.log，现场不丢
#

# 设置权限
set_perm_recursive $MODPATH/system/bin 0 0 0755 0755
chmod 0755 "$MODPATH/service.sh" "$MODPATH/customize.sh" \
          "$MODPATH/action.sh" "$MODPATH/uninstall.sh" \
          "$MODPATH/system/bin/btpanel" 2>/dev/null || true

# ========== 常量 & 共享函数 ==========
BTPANEL_INSTALL_DIR="/data/btpanel"
BTPANEL_FLAG_DIR="${BTPANEL_INSTALL_DIR}/.module_flags"
INSTALL_LOG="${BTPANEL_INSTALL_DIR}/install.log"
CRASH_LOG="${BTPANEL_INSTALL_DIR}/crash.log"
# "刷入阶段没装完" 标志：service.sh 看到就会强制立即续装
FORCE_CONTINUE_FLAG="${BTPANEL_FLAG_DIR}/force_continue_install"

mkdir -p "${BTPANEL_FLAG_DIR}" 2>/dev/null || true

logi()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [customize.sh] $1" >> "${INSTALL_LOG}" 2>/dev/null || true; ui_print "  $1"; }
loge()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [customize.sh][ERR] $1" >> "${CRASH_LOG}" 2>/dev/null || true; ui_print "  ! $1"; }

find_btpanel() {
    local p alt
    for p in /www/server/panel/bt /data/btpanel/bt /data/adb/btpanel/bt \
             /data/btpanel/panel/bt /data/linux/bt /data/linux/www/server/panel/bt \
             /usr/bin/bt; do
        [ -f "$p" ] && [ -x "$p" ] && echo "$p" && return 0
    done
    alt=$(command -v bt 2>/dev/null)
    [ -n "$alt" ] && [ -f "$alt" ] && echo "$alt" && return 0
    return 1
}

is_btpanel_installed() {
    local bt_bin=$(find_btpanel)
    local core_ok=0 d
    for d in /www/server/panel "${BTPANEL_INSTALL_DIR}/panel" /data/adb/btpanel/panel \
             /data/linux/www/server/panel; do
        [ -d "$d" ] && [ -f "$d/class/panelPlugin.py" ] && core_ok=1 && break
    done
    [ -n "$bt_bin" ] && [ $core_ok -eq 1 ] && return 0
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
    local p
    for p in /www/server/panel/bt "${BTPANEL_INSTALL_DIR}/bt"; do
        [ -x "$p" ] && "$p" stop >/dev/null 2>&1
    done
    pkill -f "BT-Panel" >/dev/null 2>&1 || true
    pkill -f "gunicorn.*panel" >/dev/null 2>&1 || true
    if [ -d "/www/server/panel" ] && [ ! -f "/www/server/panel/class/panelPlugin.py" ]; then
        rm -rf /www/server/panel 2>/dev/null || true
    fi
    if [ -d "${BTPANEL_INSTALL_DIR}/panel" ] && [ ! -f "${BTPANEL_INSTALL_DIR}/panel/class/panelPlugin.py" ]; then
        rm -rf "${BTPANEL_INSTALL_DIR}/panel" 2>/dev/null || true
    fi
}

network_ok() {
    ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 && return 0
    [ "$(getprop net.dns1 2>/dev/null)" != "" ] && return 0
    if [ -f /proc/net/route ]; then
        grep -q '^wlan0\|^eth0\|^rmnet' /proc/net/route 2>/dev/null && return 0
    fi
    return 1
}

download_file() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -sSLo "$out" "$url" --connect-timeout 30 --retry 2
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$out" "$url" --timeout=30 --tries=2
    else
        return 1
    fi
}

setup_default_credentials() {
    sleep 3
    local bt_bin=$(find_btpanel)
    [ -z "$bt_bin" ] && return 1
    echo "admin" | "$bt_bin" 5 >/dev/null 2>&1
    echo "admin" | "$bt_bin" 6 >/dev/null 2>&1
    return 0
}

# ========== 预检 ==========
bt_bin=$(find_btpanel)
found_installed=0
found_residue=0
if is_btpanel_installed; then found_installed=1
elif has_btpanel_residue; then found_residue=1
fi

ui_print ""
ui_print "  iQOO 7 宝塔面板自动安装+开机自启"
ui_print "  ==================================="
ui_print ""

# 日志轮转（512KB → 保留后 1000 行）
if [ -f "$INSTALL_LOG" ]; then
    sz=$(wc -c < "$INSTALL_LOG" 2>/dev/null || echo 0)
    if [ "$sz" -gt 524288 ]; then
        tail -n 1000 "$INSTALL_LOG" > "${INSTALL_LOG}.tmp" 2>/dev/null \
            && mv "${INSTALL_LOG}.tmp" "$INSTALL_LOG"
    fi
fi

if [ $found_installed -eq 1 ]; then
    ui_print "  ✔ 检测到已有宝塔面板安装"
    ui_print "    路径: $bt_bin"
    ui_print "    已跳过自动安装，重启后直接启动服务"
    logi "检测到已有完整安装，跳过 customize.sh 安装阶段"
elif [ $found_residue -eq 1 ]; then
    ui_print "  ⚠ 检测到宝塔面板残留目录（未完整安装）"
    ui_print "    先清理残留，再尝试安装宝塔..."
    logi "检测到残留目录，清理后尝试立刻安装"
    cleanup_btpanel_residue
    rm -f "${BTPANEL_FLAG_DIR}/installed" "${BTPANEL_FLAG_DIR}/install.lock"
fi

# ========== 核心：刷入阶段直接自动安装（有网就装，超时写续装标志让开机续装）==========
if ! is_btpanel_installed; then
    ui_print ""
    if network_ok; then
        ui_print "  ↓ 检测到网络，刷入阶段立即安装宝塔面板..."
        ui_print "    （最多等待 480 秒，装不完会在重启后继续）"
        logi "刷入阶段检测到网络，立即开始安装宝塔面板"

        # 写续装标志（一旦开始安装就先写，成功再清，失败或超时也留着让 service.sh 兜底）
        echo "1" > "$FORCE_CONTINUE_FLAG"

        {
            echo ""
            echo "========== 刷入阶段安装开始 $(date '+%Y-%m-%d %H:%M:%S') =========="
        } >> "$INSTALL_LOG" 2>&1

        install_script="/tmp/bt_install_panel.sh"
        if download_file "https://download.bt.cn/install/install_panel.sh" "$install_script"; then
            chmod 0755 "$install_script"
            mkdir -p /www 2>/dev/null
            chmod 755 /www 2>/dev/null || true

            # 在后台开始安装，前台最多等 480 秒（8 分钟）
            # 注意：此处在 () 子 shell 中运行，不能用 local 关键字
            (
                echo "y" | bash "$install_script" ed8484bec
                rc=$?
                echo "========== 安装脚本结束 rc=$rc $(date '+%Y-%m-%d %H:%M:%S') =========="
                if is_btpanel_installed; then
                    echo "[OK] 刷入阶段安装完成"
                    setup_default_credentials
                    touch "${BTPANEL_FLAG_DIR}/installed"
                    rm -f "$FORCE_CONTINUE_FLAG"
                    # 顺手启动一次（如果刷入环境允许）
                    b2=$(find_btpanel)
                    if [ -n "$b2" ]; then
                        export BT_IGNORE=1
                        nohup "$b2" start >/dev/null 2>&1 &
                    fi
                    echo "[OK] 刷入阶段全部流程结束 rc=0"
                else
                    echo "[WARN] 刷入阶段未完成，将在重启后继续（force_continue_install 已写）"
                    echo "1" > "$FORCE_CONTINUE_FLAG"
                fi
                exit 0
            ) >> "$INSTALL_LOG" 2>&1 &

            install_pid=$!
            waited=0
            # 前台等最多 480 秒
            while [ $waited -lt 480 ]; do
                kill -0 "$install_pid" 2>/dev/null || break
                sleep 5
                waited=$((waited + 5))
                # 每 30 秒输出一条进度提示，防止 Magisk UI 假死
                if [ $((waited % 30)) -eq 0 ]; then
                    ui_print "    安装中... 已等待 ${waited}s（装不完重启继续）"
                fi
            done

            if is_btpanel_installed; then
                ui_print ""
                ui_print "  ✅ 宝塔面板已安装完成！"
                ui_print "    默认账号: admin  密码: admin"
                logi "刷入阶段已成功安装宝塔面板"
                rm -f "$FORCE_CONTINUE_FLAG"
            else
                # 没装完 → 标志续装（前面已写，这里确认一遍）
                echo "1" > "$FORCE_CONTINUE_FLAG"
                ui_print ""
                ui_print "  ⚠ 安装未在 480s 内完成，已写续装标志"
                ui_print "    重启设备后 service.sh 会立刻继续安装（联网环境）"
                loge "customize.sh 安装未完成，设 force_continue_install 标志"
            fi
        else
            loge "下载 install_panel.sh 失败"
            ui_print "  ❌ 下载安装脚本失败，已写续装标志"
            ui_print "    重启后 service.sh 会重试"
        fi
    else
        # 没网 → 写续装标志，service.sh 一开机就强制续装
        echo "1" > "$FORCE_CONTINUE_FLAG"
        ui_print "  ⚠ 刷入环境无网络，无法立即安装"
        ui_print "    已写续装标志，重启联网后 service.sh 会立刻安装"
        logi "刷入环境无网络，设 force_continue_install 标志，等待开机续装"
    fi
fi

# 失败日志保护：如果检测到有 install.lock 或 force_continue 都算异常现场
if [ -f "${BTPANEL_FLAG_DIR}/install.lock" ] || [ -f "$FORCE_CONTINUE_FLAG" ]; then
    cp -f "$INSTALL_LOG" "${BTPANEL_FLAG_DIR}/install.latest.log" 2>/dev/null || true
fi

ui_print ""
ui_print "  功能说明:"
ui_print "  ├ 刷入后若网络可用会直接开始联网安装宝塔（最多等 8 分钟）"
ui_print "  ├ 装不完/没网 → 重启后 service.sh 立刻续装"
ui_print "  ├ 安装完成后自动启动面板服务，后续每次开机自启"
ui_print "  ├ 面板默认账号: admin   密码: admin"
ui_print "  ├ 介绍: 动态显示【已启动/已关闭】两种最终状态"
ui_print "  └ 操作: 点右下按钮 → 音量上=开启 音量下=关闭"
ui_print ""
ui_print "  日志位置:"
ui_print "  • 安装日志: /data/btpanel/install.log"
ui_print "  • 失败日志: /data/btpanel/crash.log"
ui_print "  • 命令调试: btpanel status / start / stop / restart"
ui_print ""

# 确保标志目录存在 + 权限可写
mkdir -p "${BTPANEL_FLAG_DIR}" 2>/dev/null || true
chmod 0755 "${BTPANEL_INSTALL_DIR}" "${BTPANEL_FLAG_DIR}" 2>/dev/null || true

exit 0
