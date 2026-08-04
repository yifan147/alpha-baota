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
    for p in /www/server/panel/bt /data/btpanel/bt /data/btpanel/server/panel/bt \
             /data/adb/btpanel/bt /data/btpanel/panel/bt /data/linux/bt \
             /data/linux/www/server/panel/bt /usr/bin/bt; do
        [ -f "$p" ] && [ -x "$p" ] && echo "$p" && return 0
    done
    alt=$(command -v bt 2>/dev/null)
    [ -n "$alt" ] && [ -f "$alt" ] && echo "$alt" && return 0
    return 1
}

is_btpanel_installed() {
    local bt_bin=$(find_btpanel)
    local core_ok=0 d
    for d in /www/server/panel /data/btpanel/server/panel /data/btpanel/panel \
             /data/adb/btpanel/panel /data/linux/www/server/panel; do
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
    # Android /tmp 通常不存在 → 用 /data/local/tmp
    local out_dir
    out_dir=$(dirname "$out" 2>/dev/null)
    [ -n "$out_dir" ] && mkdir -p "$out_dir" 2>/dev/null
    if command -v curl >/dev/null 2>&1; then
        curl -sSLo "$out" "$url" --connect-timeout 30 --retry 2
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$out" "$url" --timeout=30 --tries=2
    else
        return 1
    fi
}

# ========== /www 只读文件系统兼容 ==========
# Android 根文件系统通常只读 → 需要特殊处理 /www
# 返回 0 = /www 可写；返回 1 = 不可写（调用方需 fallback 到 /data/btpanel）
ensure_www_writable() {
    # 如果 post-fs-data.sh 已经 bind mount 成功
    if [ -d /www ] && [ -w /www ]; then
        return 0
    fi
    # 方法 1：直接创建
    mkdir -p /www 2>/dev/null
    if [ -d /www ] && touch /www/.write_test 2>/dev/null; then
        rm -f /www/.write_test
        return 0
    fi
    # 方法 2：remount / 为 rw
    mount -o remount,rw / 2>/dev/null
    mkdir -p /www 2>/dev/null
    # 不 remount 回 ro，保持 rw 让后续安装能写
    if [ -d /www ] && touch /www/.write_test 2>/dev/null; then
        rm -f /www/.write_test
        return 0
    fi
    # 方法 3：bind mount /data 到 /www（如果 /www 存在）
    mkdir -p "${BTPANEL_INSTALL_DIR}/www_data" 2>/dev/null
    if [ -d /www ]; then
        mount --bind "${BTPANEL_INSTALL_DIR}/www_data" /www 2>/dev/null
        if [ -w /www ]; then
            return 0
        fi
    fi
    # 全部失败 → fallback
    return 1
}

# 如果 /www 不可写，修改宝塔安装脚本使用 /data/btpanel 代替 /www
# 同时处理 /usr/bin/bt → /data/btpanel/bt
patch_install_script_for_data() {
    local script="$1"
    if [ ! -f "$script" ]; then return 1; fi
    # 替换所有 /www → /data/btpanel（覆盖 server, wwwroot, backup 等子路径）
    sed -i 's|/www/server|/data/btpanel/server|g' "$script" 2>/dev/null
    sed -i 's|/www/wwwroot|/data/btpanel/wwwroot|g' "$script" 2>/dev/null
    sed -i 's|/www/backup|/data/btpanel/backup|g' "$script" 2>/dev/null
    sed -i 's|/www/wwwlogs|/data/btpanel/wwwlogs|g' "$script" 2>/dev/null
    # /usr/bin/bt → /data/btpanel/bt（Android /usr/bin 只读）
    sed -i 's|/usr/bin/bt|/data/btpanel/bt|g' "$script" 2>/dev/null
    sed -i 's|/usr/bin/python|/data/btpanel/server/python/bin/python|g' "$script" 2>/dev/null
    # /etc/init.d/bt → /data/btpanel/init.d/bt
    sed -i 's|/etc/init.d/bt|/data/btpanel/init.d/bt|g' "$script" 2>/dev/null
    # 创建 fallback 目录
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

# ========== 核心：只写续装标志，安装统一放到开机 service.sh 阶段 ==========
# 原因：刷入环境（recovery/update-binary）缺少 bash、curl 写入路径受限、且用户反馈「有网络直接秒失败」
# 统一由开机后 service.sh 联网下载安装 → 更稳定、可观察进度、动态显示安装状态
if ! is_btpanel_installed; then
    # 不管有没有网络都写 force_continue_install 标志，service.sh 开机后优先检测
    echo "1" > "$FORCE_CONTINUE_FLAG"

    ui_print ""
    if network_ok; then
        ui_print "  ✅ 检测到网络"
    else
        ui_print "  ⚠ 暂无网络"
    fi
    ui_print "  ↓ 将在重启后自动联网安装宝塔面板"
    ui_print "    （service.sh 阶段自动执行，可在介绍中实时查看安装状态）"
    logi "刷入阶段：不直接安装，已写 force_continue_install → service.sh 开机后自动装"

    ui_print ""
    ui_print "  安装进度查看方式:"
    ui_print "  ├ 模块介绍: 动态显示「安装中 ↓ / 安装失败 ✗ / 已启动 ▶ / 已关闭 ■」"
    ui_print "  └ 查看日志: btpanel log 或 tail -f /data/btpanel/install.log"
else
    # 已经完整安装过 → 保险清标志
    rm -f "$FORCE_CONTINUE_FLAG"
fi

# 失败日志保护：保留 install.log 存档
if [ -f "$INSTALL_LOG" ]; then
    cp -f "$INSTALL_LOG" "${BTPANEL_FLAG_DIR}/install.latest.log" 2>/dev/null || true
fi

ui_print ""
ui_print "  功能说明:"
ui_print "  ├ 重启后 service.sh 自动联网安装宝塔（检测到网络立即开始）"
ui_print "  ├ 安装完成后自动启动面板服务，后续每次开机自启"
ui_print "  ├ 面板默认账号: admin   密码: admin"
ui_print "  ├ 介绍: 动态显示【安装中 ↓ / 安装失败 ✗ / 已启动 ▶ / 已关闭 ■】"
ui_print "  └ 操作: 点右下按钮 → 音量上=开启 音量下=关闭"
ui_print ""
ui_print "  日志位置:"
ui_print "  • 安装日志: /data/btpanel/install.log"
ui_print "  • 失败日志: /data/btpanel/crash.log"
ui_print "  • 命令调试: btpanel status / start / stop / restart / log"
ui_print ""

# 确保标志目录存在 + 权限可写
mkdir -p "${BTPANEL_FLAG_DIR}" 2>/dev/null || true
chmod 0755 "${BTPANEL_INSTALL_DIR}" "${BTPANEL_FLAG_DIR}" 2>/dev/null || true

exit 0
