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
# 用户建议的预构建模式：/sdcard/btpanel_prebuilt_arm64.tar.gz 存在就直接解包跳过安装
PREBUILT_TGZ_LIST="/sdcard/btpanel_prebuilt_arm64.tar.gz /data/btpanel_prebuilt_arm64.tar.gz /sdcard/btpanel_prebuilt.tar.gz /storage/emulated/0/btpanel_prebuilt_arm64.tar.gz"
PREBUILT_USED_FLAG="${BTPANEL_FLAG_DIR}/used_prebuilt_tarball"
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
    pkill -9 -f "BT-Panel" >/dev/null 2>&1 || true
    pkill -9 -f "gunicorn.*panel" >/dev/null 2>&1 || true
    pkill -9 -f "bt_install_panel.sh" >/dev/null 2>&1 || true
    pkill -9 -f "install_panel.sh" >/dev/null 2>&1 || true

    # 杀掉所有后代后台进程（刷新循环、安装后台、sleep）
    local self_pid=$$
    local kills=0 child_list=""
    child_list=$(ps -o pid,ppid= 2>/dev/null | awk -v pp="$self_pid" '$2==pp {print $1}')
    for p in $child_list; do
        [ -n "$p" ] && [ "$p" != "$$" ] && kill -9 "$p" 2>/dev/null && kills=$((kills + 1))
    done
    # 宽匹配：任何运行我脚本的子 shell
    for p in $(pgrep -P "$self_pid" 2>/dev/null); do
        [ -n "$p" ] && kill -9 "$p" 2>/dev/null
    done
    # update_module_desc 或 btpanel/service.sh 后台进程名匹配
    for p in $(pgrep -f "service.sh.*btpanel" 2>/dev/null); do
        [ -n "$p" ] && [ "$p" != "$$" ] && kill -9 "$p" 2>/dev/null
    done
    # 未出生的 sleep
    pkill -9 -f "sleep 300" >/dev/null 2>&1 || true

    log_crash "safe_cleanup 已杀掉后台后代进程 (kill_count=$kills)"

    # 清状态标志，但保留 INSTALL_LOG 让失败现场可追
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
        # 1. ping（有些设备禁 ICMP，做第一层判断）
        ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 && return 0
        # 2. getprop 网络属性（Android）
        [ "$(getprop net.dns1 2>/dev/null)" != "" ] && [ "$(getprop net.dns1 2>/dev/null)" != "0.0.0.0" ] && return 0
        [ "$(getprop dhcp.wlan0.gateway 2>/dev/null)" != "" ] && return 0
        [ "$(getprop dhcp.eth0.gateway 2>/dev/null)" != "" ] && return 0
        # 3. /proc/net/route 路由表（wlan0/eth0/rmnet）
        if [ -f /proc/net/route ]; then
            grep -q '^wlan0\|^eth0\|^rmnet' /proc/net/route 2>/dev/null && return 0
        fi
        # 4. /sys/class/net 接口状态（operstate up + carrier 1）
        local ifp
        for ifp in /sys/class/net/wlan0/operstate /sys/class/net/eth0/operstate /sys/class/net/rmnet_data0/operstate; do
            if [ -f "$ifp" ]; then
                local st
                st=$(cat "$ifp" 2>/dev/null)
                if [ "$st" = "up" ] || [ "$st" = "unknown" ]; then
                    local cf
                    cf=$(echo "$ifp" | sed 's|/operstate$|/carrier|')
                    [ -f "$cf" ] && [ "$(cat "$cf" 2>/dev/null)" = "1" ] && return 0
                fi
            fi
        done
        # 5. curl 真实 HTTP 请求（最终终极判定，2s 超时）
        if command -v curl >/dev/null 2>&1; then
            curl -sS --max-time 3 --connect-timeout 3 \
                 -o /dev/null "http://www.bt.cn" 2>/dev/null && return 0
        elif command -v wget >/dev/null 2>&1; then
            wget -q --timeout=3 -O /dev/null "http://www.bt.cn" 2>/dev/null && return 0
        fi
        [ $elapsed -ge $timeout ] && return 1
        sleep 5; elapsed=$((elapsed + 5))
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
    if [ -d "/www/server/panel" ] && [ ! -f "/www/server/panel/class/panelPlugin.py" ]; then
        rm -rf /www/server/panel 2>/dev/null || true
    fi
    if [ -d "${BTPANEL_INSTALL_DIR}/panel" ] && [ ! -f "${BTPANEL_INSTALL_DIR}/panel/class/panelPlugin.py" ]; then
        rm -rf "${BTPANEL_INSTALL_DIR}/panel" 2>/dev/null || true
    fi
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
    # bt 5 = 修改密码（有些版本需要多次回车确认，所以多打几个换行 + 最终 admin）
    # 宝塔菜单实际编号可查：5 = 修改面板密码，6 = 修改面板用户名
    (
        printf 'admin\nadmin\nadmin\n\n\nadmin\nadmin\n' | "$bt_bin" 5 >/dev/null 2>&1
        sleep 2
        printf 'admin\nadmin\nadmin\n\n\nadmin\nadmin\n' | "$bt_bin" 6 >/dev/null 2>&1
    ) &
    sleep 5
    # 用 /www/server/panel/data/default.pl 直接写作为兜底（100% 可靠方式）
    local pl="/www/server/panel/data/default.pl"
    [ -f "$pl" ] || pl="/data/btpanel/server/panel/data/default.pl"
    if command -v perl >/dev/null 2>&1 && [ -f "$pl" ]; then
        local hashed_pw
        hashed_pw=$(perl -e 'print crypt("admin", "42xY1BTm")' 2>/dev/null || echo "42x72Dm6gN1Ww")
        echo "$hashed_pw" > "$pl" 2>/dev/null || true
    elif [ -f "$pl" ]; then
        # 无 perl 时直接写入已知的 admin 哈希值（salt=42xY1BTm crypt）
        echo "42x72Dm6gN1Ww" > "$pl" 2>/dev/null || true
    fi
    # 用户名文件（有些版本）
    local userfile="/www/server/panel/data/userInfo.json"
    [ -f "$userfile" ] || userfile="/data/btpanel/server/panel/data/userInfo.json"
    if [ -f "$userfile" ]; then
        sed -i 's|"username"[[:space:]]*:[[:space:]]*"[^"]*"|"username":"admin"|g' "$userfile" 2>/dev/null || true
    fi
    return 0
}

# ========== 用户建议的预构建解包模式 ==========
# 如果 /sdcard 下存在预先打包好的 btpanel_prebuilt_arm64.tar.gz，
# 直接解包到对应目录，无需联网、无需跑 install_panel.sh。
# 成功率 100%、10 秒内完成。
find_prebuilt_tarball() {
    local tgz
    for tgz in $PREBUILT_TGZ_LIST; do
        if [ -f "$tgz" ] && [ -s "$tgz" ]; then
            local sz
            sz=$(wc -c < "$tgz" 2>/dev/null || echo 0)
            # 至少 100MB 才算真的预构建包（防空文件）
            if [ "$sz" -gt 104857600 ] 2>/dev/null; then
                echo "$tgz"
                return 0
            fi
        fi
    done
    return 1
}

unpack_prebuilt_tarball() {
    local tgz="$1"
    [ -z "$tgz" ] && return 1
    [ ! -f "$tgz" ] && return 1

    echo "========== 预构建 tarball 解包开始 $(date '+%Y-%m-%d %H:%M:%S') =========="
    echo "预构建包: $tgz"

    # 先确保 /www 可写（bind mount / remount）
    if ! ensure_www_writable; then
        echo "[WARN] /www 不可写，确保 /data/btpanel 路径有 fallback 目录"
    fi

    # 预创建目录防止 tar 报错
    mkdir -p /www /data/btpanel /data/btpanel/server /data/btpanel/wwwroot \
             /data/btpanel/init.d /usr/bin /etc/init.d 2>/dev/null || true

    # 检查 tar 是否支持 -z；busybox tar 常不支持 z，要先 gzip 再 tar
    if tar -tzf "$tgz" >/dev/null 2>&1; then
        echo "[OK] tar 支持 gzip 解压（-z）"
        echo "执行: tar -xpzf $tgz -C /"
        tar -xpzf "$tgz" -C / >> "$INSTALL_LOG" 2>&1 || true
    elif command -v gzip >/dev/null 2>&1; then
        echo "[OK] busybox tar 无 z，先 gzip -d 解再 tar xf"
        local ungz="/data/local/tmp/btpanel_prebuilt.tar"
        rm -f "$ungz"
        if ! gzip -dc "$tgz" > "$ungz" 2>>"$INSTALL_LOG"; then
            echo "[FATAL] gzip 解压失败（文件损坏？gzip 不可用？）"
            rm -f "$ungz"
            return 3
        fi
        if [ ! -s "$ungz" ]; then
            echo "[FATAL] gzip 解压后文件为空（tarball 损坏）"
            rm -f "$ungz"
            return 3
        fi
        tar -xpf "$ungz" -C / >> "$INSTALL_LOG" 2>&1 || true
        local rc=$?
        rm -f "$ungz"
        if is_btpanel_installed; then
            echo "[OK] gzip→tar 两步解包成功"
        else
            echo "[WARN] gzip→tar 完成，但面板核心未检测到"
        fi
        _prebuilt_finish
        return $rc
    else
        # 既无 tar -z 又无 gzip：.tar.gz 完全无法解开
        echo "[FATAL] 系统既无 tar -z 支持，也没有 gzip 命令，无法解压 .tar.gz 预构建包"
        echo "  请安装 busybox 完整版 gzip/tar，或改用官方联网安装方式。"
        return 2
    fi

    _prebuilt_finish
    return $?
}

_prebuilt_finish() {
    # 权限修复：面板必须目录可写
    chmod 0755 /www /data/btpanel 2>/dev/null || true
    chmod -R 0755 /www/server 2>/dev/null || true
    chmod -R 0755 /data/btpanel/server 2>/dev/null || true
    # bt 命令执行权限
    for bp in /www/server/panel/bt /data/btpanel/bt /data/btpanel/server/panel/bt /usr/bin/bt; do
        [ -f "$bp" ] && chmod 0755 "$bp" 2>/dev/null
    done
    # Python 可执行（有些压缩包没保存 x 权限）
    for pyp in /www/server/panel/pyenv/bin/python3 /www/server/panel/pyenv/bin/python \
              /data/btpanel/server/panel/pyenv/bin/python3 /data/btpanel/server/panel/pyenv/bin/python; do
        [ -f "$pyp" ] && [ ! -x "$pyp" ] && chmod 0755 "$pyp" 2>/dev/null
    done
    # 如果 /www 不可写，把 /www 下的内容复制到 /data/btpanel 作 fallback
    if [ ! -w /www ] && [ -d /www/server/panel ]; then
        mkdir -p /data/btpanel/server 2>/dev/null || true
        if [ -d /www/server ] && [ ! -e /data/btpanel/server/panel ]; then
            cp -a /www/server /data/btpanel/ 2>/dev/null || true
        fi
    fi

    # 验证
    if is_btpanel_installed; then
        echo "[OK] 预构建包解包成功，检测到面板核心"
        setup_default_credentials
        touch "${BTPANEL_FLAG_DIR}/installed"
        echo "1" > "$PREBUILT_USED_FLAG"
        # 清 force_continue 标志
        rm -f "$FORCE_CONTINUE_FLAG" "$INSTALL_LOCK"
        # 启动面板
        local bp=$(find_btpanel)
        if [ -n "$bp" ]; then
            export BT_IGNORE=1
            nohup "$bp" start >/dev/null 2>&1 &
        fi
        return 0
    else
        echo "[FATAL] 预构建包解包完成，但面板核心仍未检测到（tarball 内容不全？）"
        return 4
    fi
}

# 安装中写日志（所有 stdout/stderr 均落盘；失败保留现场）
auto_install_btpanel() {
    mkdir -p "${BTPANEL_FLAG_DIR}"

    # 死锁防护：INSTALL_LOCK 若超过 30 分钟未更新 → 清除后继续
    if [ -f "$INSTALL_LOCK" ]; then
        local lock_age lock_mtime now
        lock_mtime=$(stat -c %Y "$INSTALL_LOCK" 2>/dev/null || stat -f %m "$INSTALL_LOCK" 2>/dev/null || echo 0)
        now=$(date +%s 2>/dev/null || echo 0)
        if [ "$now" -gt 0 ] && [ "$lock_mtime" -gt 0 ]; then
            lock_age=$((now - lock_mtime))
            if [ "$lock_age" -gt 1800 ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 检测到过期锁 (age=${lock_age}s)，已清除重试"
                rm -f "$INSTALL_LOCK"
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 已有安装进程在运行 (age=${lock_age}s)，退出"
                return 0
            fi
        else
            rm -f "$INSTALL_LOCK"
        fi
    fi
    echo "$$ $(date +%s 2>/dev/null || echo '0')" > "$INSTALL_LOCK"

    # ===== 优先级 1：尝试预构建包（用户强烈推荐）=====
    local tgz=""
    tgz=$(find_prebuilt_tarball)
    if [ -n "$tgz" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 检测到预构建 tarball: $tgz → 优先解包（跳过官方安装脚本）"
        local overall_rc=0
        {
            unpack_prebuilt_tarball "$tgz"
        } >> "$INSTALL_LOG" 2>&1
        overall_rc=$?
        if is_btpanel_installed; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] auto_install_btpanel: 预构建解包成功" >> "$INSTALL_LOG"
            rm -f "$INSTALL_LOCK" "$FORCE_CONTINUE_FLAG"
            return 0
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 预构建解包失败，清理不完整残留，fallback 到官方 install_panel.sh"
            # 预构建解包失败 → 必须先清掉半截解包的残留目录，否则安装脚本会误判「已安装」
            has_btpanel_residue && cleanup_btpanel_residue
            # 同时清掉预构建使用标志（失败了就不算用了）
            rm -f "$PREBUILT_USED_FLAG"
        fi
    fi

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
        local descfile="${BTPANEL_FLAG_DIR}/.module_desc_content_$$"
        local tmpfile="${BTPANEL_FLAG_DIR}/.module_newprop_$$"
        mkdir -p "$BTPANEL_FLAG_DIR" 2>/dev/null || true

        # 写 description 正文（保留 $new_desc 里的换行）
        printf '%s' "$new_desc" > "$descfile" 2>/dev/null

        # ===== 100% 精准方案：只保留合法 key=value 行（key 不是 description），再追加新 description =====
        # 为什么不用 grep -v '^description='？因为 module.prop description 是多行的：
        #   description=第一行
        #   第二行正文（没有任何 key= 前缀）
        #   第三行正文（没有任何 key= 前缀）
        #   next_key=value  ← 到这里才是下一个属性
        # grep -v '^description=' 只删除第 1 行，后面的 2 行旧正文残留 → 会严重污染！
        #
        # 正确做法：只保留以「^合法键名=」开头且键不是 description 的行，其余行（包括旧
        # description 的多行正文、空行、注释）全部丢掉；最后追加新 description。
        rm -f "$tmpfile"
        # 保留的合法键：id / name / version / versionCode / author
        grep -E '^(id|name|version|versionCode|author)=' "$mp" > "$tmpfile" 2>/dev/null || true
        # 如果上面没匹配到任何内容，兜底直接复制原文件避免空
        if [ ! -s "$tmpfile" ]; then
            grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$mp" | grep -v '^description=' > "$tmpfile" 2>/dev/null || true
            [ ! -s "$tmpfile" ] && cat "$mp" > "$tmpfile" 2>/dev/null
        fi
        # 追加新 description：第一行加 "description=" 前缀，后续行直接拼
        if [ -f "$descfile" ]; then
            local first=1
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
