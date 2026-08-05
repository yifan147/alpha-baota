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
    # 杀掉本模块启动的后台进程（只匹配 btpanel 相关，避免误杀其他模块的 service.sh）
    for p in $(pgrep -f "btpanel.*service\.sh\|service\.sh.*btpanel" 2>/dev/null); do
        [ -n "$p" ] && [ "$p" != "$$" ] && kill -9 "$p" 2>/dev/null
    done

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
        # 1. ping IP（有些设备禁 ICMP，做第一层判断）
        ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 && return 0
        # 2. getprop 网络属性（Android）— 但这只是"有DNS配置"，不代表DNS能解析！
        #    放宽为：只作为"网络可能就绪"的信号，不直接 return 0
        local dns_ready=0
        [ "$(getprop net.dns1 2>/dev/null)" != "" ] && [ "$(getprop net.dns1 2>/dev/null)" != "0.0.0.0" ] && dns_ready=1
        [ "$(getprop dhcp.wlan0.gateway 2>/dev/null)" != "" ] && dns_ready=1
        [ "$(getprop dhcp.eth0.gateway 2>/dev/null)" != "" ] && dns_ready=1
        # 3. /proc/net/route 路由表
        if [ -f /proc/net/route ]; then
            grep -q '^wlan0\|^eth0\|^rmnet' /proc/net/route 2>/dev/null && dns_ready=1
        fi
        # 4. /sys/class/net 接口状态
        local ifp
        for ifp in /sys/class/net/wlan0/operstate /sys/class/net/eth0/operstate /sys/class/net/rmnet_data0/operstate; do
            if [ -f "$ifp" ]; then
                local st
                st=$(cat "$ifp" 2>/dev/null)
                if [ "$st" = "up" ] || [ "$st" = "unknown" ]; then
                    local cf
                    cf=$(echo "$ifp" | sed 's|/operstate$|/carrier|')
                    [ -f "$cf" ] && [ "$(cat "$cf" 2>/dev/null)" = "1" ] && dns_ready=1
                fi
            fi
        done
        # 5. 关键：DNS 有配置时，做真实 DNS 解析测试（ping 域名）
        #    避免「net.dns1 有值但 DNS 实际未生效」的误判
        if [ $dns_ready -eq 1 ]; then
            # ping 域名（会触发 DNS 解析）；-W 3 超时
            if ping -c 1 -W 3 download.bt.cn >/dev/null 2>&1; then
                return 0
            fi
            # getent / nslookup 兜底
            if command -v getent >/dev/null 2>&1; then
                getent hosts download.bt.cn >/dev/null 2>&1 && return 0
            fi
            # curl HTTP 请求最终判定（需要 DNS 解析 www.bt.cn）
            if command -v curl >/dev/null 2>&1; then
                curl -sS --max-time 5 --connect-timeout 5 \
                     -o /dev/null "http://www.bt.cn" 2>/dev/null && return 0
            elif command -v wget >/dev/null 2>&1; then
                wget -q --timeout=5 -O /dev/null "http://www.bt.cn" 2>/dev/null && return 0
            fi
            # DNS 有配置但解析失败 → 尝试设置公共 DNS（每轮只设一次，避免刷屏）
            if [ $elapsed -eq 0 ]; then
                echo "[wait_for_network] DNS 解析失败，尝试设置公共 DNS 223.5.5.5..." 2>/dev/null
                setprop net.dns1 223.5.5.5 2>/dev/null || true
                setprop net.dns2 8.8.8.8 2>/dev/null || true
                # 重新解析
                ping -c 1 -W 3 download.bt.cn >/dev/null 2>&1 && return 0
            fi
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
    # 关键：先删除旧文件，防止下载失败后执行上次的残留脚本
    rm -f "$out" 2>/dev/null
    local rc=1
    if command -v curl >/dev/null 2>&1; then
        curl -sSLo "$out" "$url" --connect-timeout 30 --retry 3 2>&1
        rc=$?
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$out" "$url" --timeout=30 --tries=3 2>&1
        rc=$?
    else
        return 1
    fi
    # 验证：下载失败或文件为空 → 清除并返回错误
    if [ $rc -ne 0 ] || [ ! -s "$out" ]; then
        rm -f "$out" 2>/dev/null
        return 1
    fi
    return 0
}

# ========== /www 只读文件系统兼容 ==========
ensure_www_writable() {
    # 如果 post-fs-data.sh 已经 bind mount 成功
    if [ -d /www ] && [ -w /www ]; then return 0; fi
    # 方法 1：直接创建
    mkdir -p /www 2>/dev/null
    if [ -d /www ] && touch /www/.write_test 2>/dev/null; then
        rm -f /www/.write_test; return 0
    fi
    # 方法 2：bind mount /data 到 /www（最安全，不改根文件系统）
    mkdir -p "${BTPANEL_INSTALL_DIR}/www_data" 2>/dev/null
    if [ -d /www ]; then
        mount --bind "${BTPANEL_INSTALL_DIR}/www_data" /www 2>/dev/null
        if [ -w /www ]; then return 0; fi
    else
        # /www 不存在 → 创建并 bind mount
        mkdir -p /www 2>/dev/null
        mount --bind "${BTPANEL_INSTALL_DIR}/www_data" /www 2>/dev/null
        if [ -w /www ]; then return 0; fi
    fi
    # 方法 3（最后手段）：remount / 为 rw（有风险，但安装必须可写）
    mount -o remount,rw / 2>/dev/null
    mkdir -p /www 2>/dev/null
    if [ -d /www ] && touch /www/.write_test 2>/dev/null; then
        rm -f /www/.write_test
        # 标记需要恢复 ro（安装完成后恢复）
        touch "${BTPANEL_FLAG_DIR}/.need_remount_ro" 2>/dev/null
        return 0
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
    # /tmp → /data/local/tmp（仅当 /tmp 不可写时才替换，避免破坏可写 /tmp 的正常使用）
    if [ ! -w /tmp ]; then
        sed -i 's|/tmp/|/data/local/tmp/|g' "$script" 2>/dev/null
    fi
    mkdir -p /data/btpanel/server /data/btpanel/wwwroot /data/btpanel/bt 2>/dev/null
    return 0
}

# ========== Android 环境兼容：执行安装脚本前准备 ==========
# 官方 install_panel.sh 假设 Linux 环境，需要做以下适配：
# 1. /tmp 目录（tee/log 写入）→ 创建或用 /data/local/tmp
# 2. HOME 变量（cd ~ 展开）→ 设置为 /data/btpanel
# 3. /etc/hostname /etc/issue /etc/redhat-release（只读）→ 创建 dummy 或 patch 脚本
prepare_android_env() {
    # 1. 创建 /tmp（如果根文件系统可写）
    mkdir -p /tmp 2>/dev/null
    if [ ! -d /tmp ] || [ ! -w /tmp ]; then
        # /tmp 不存在或不可写 → bind mount 或 symlink
        mkdir -p /data/local/tmp 2>/dev/null
        # 尝试创建 /tmp 并 bind mount
        mkdir -p /tmp 2>/dev/null
        mount -o bind /data/local/tmp /tmp 2>/dev/null || true
    fi
    # 验证 /tmp 可写
    if [ ! -w /tmp ]; then
        # 最后兜底：创建一个 tmpfs
        mkdir -p /tmp 2>/dev/null
        mount -t tmpfs tmpfs /tmp 2>/dev/null || true
    fi

    # 2. 设置 HOME（cd ~ 需要）
    export HOME="${HOME:-/data/btpanel}"
    [ -d "$HOME" ] || mkdir -p "$HOME" 2>/dev/null

    # 3. /etc/hostname /etc/issue /etc/redhat-release
    #    官方安装脚本读这些做 OS 检测，Android 没有但只读 → 创建 dummy
    #    先尝试在 /etc/ 下创建，失败则 patch 安装脚本跳过
    local etc_writable=0
    if [ -d /etc ]; then
        touch /etc/.bt_write_test 2>/dev/null && rm -f /etc/.bt_write_test && etc_writable=1
    fi
    if [ $etc_writable -eq 1 ]; then
        [ ! -f /etc/hostname ] && echo "android" > /etc/hostname 2>/dev/null || true
        [ ! -f /etc/issue ] && echo "Android" > /etc/issue 2>/dev/null || true
        [ ! -f /etc/redhat-release ] && echo "CentOS Linux release 7.0 (Core)" > /etc/redhat-release 2>/dev/null || true
    fi
    # 如果 /etc 不可写，后续 patch_install_script_for_android 会处理

    return 0
}

# patch 安装脚本中不兼容 Android 的部分（/etc/hostname 写入、OS检测等）
patch_install_script_for_android() {
    local script="$1"
    [ ! -f "$script" ] && return 1

    # /tmp → /data/local/tmp（如果 /tmp 不可写）
    if [ ! -w /tmp ]; then
        sed -i 's|/tmp/|/data/local/tmp/|g' "$script" 2>/dev/null
    fi

    # /etc/hostname 写入 → 重定向到 /data/btpanel/hostname（Android /etc 只读）
    if [ ! -w /etc ]; then
        sed -i 's|/etc/hostname|/data/btpanel/hostname|g' "$script" 2>/dev/null
        sed -i 's|/etc/issue|/data/btpanel/issue|g' "$script" 2>/dev/null
        sed -i 's|/etc/redhat-release|/data/btpanel/redhat-release|g' "$script" 2>/dev/null
        # 创建 dummy 文件
        echo "android" > /data/btpanel/hostname 2>/dev/null || true
        echo "Android" > /data/btpanel/issue 2>/dev/null || true
        echo "CentOS Linux release 7.0 (Core)" > /data/btpanel/redhat-release 2>/dev/null || true
    fi

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
    local cred_pid=$!
    # 等待最多 15 秒让 bt 5/6 完成（超时不阻塞主流程）
    local waited=0
    while [ $waited -lt 15 ]; do
        kill -0 "$cred_pid" 2>/dev/null || break
        sleep 1; waited=$((waited + 1))
    done
    # 如果还在跑就让它后台继续，不阻塞
    kill -0 "$cred_pid" 2>/dev/null && log_crash "setup_default_credentials: bt 5/6 仍在执行(${waited}s)，后台继续" || true
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

        # ===== 关键：检查 bash 是否可用 =====
        # 官方 install_panel.sh 使用 bash 语法（数组、((expr)) 等），
        # 如果系统只有 sh/ash（busybox），执行必然报 syntax error
        if [ -z "$SH_BIN" ] || [ ! -x "$SH_BIN" ]; then
            echo "[FATAL] 找不到可用的 shell 解释器（需要 bash）"
            echo "  Android busybox sh 无法执行 install_panel.sh 的 bash 语法"
            exit 1
        fi
        # 检查是否真的是 bash（不是 sh/ash）
        local is_bash=0
        "$SH_BIN" -c '[[ 1 == 1 ]]' >/dev/null 2>&1 && is_bash=1
        if [ $is_bash -eq 0 ]; then
            echo "[WARN] SH_BIN=$SH_BIN 不是 bash，install_panel.sh 可能语法报错"
            echo "  尝试查找系统中的 bash..."
            local found_bash=""
            for bp in /system/bin/bash /system/xbin/bash /data/adb/magisk/busybox/bash \
                      /data/adb/magisk/.magisk/busybox/bash /sbin/bash /usr/bin/bash; do
                if [ -x "$bp" ]; then
                    found_bash="$bp"
                    break
                fi
            done
            if [ -n "$found_bash" ]; then
                SH_BIN="$found_bash"
                echo "  [OK] 找到 bash: $SH_BIN"
            else
                echo "[FATAL] 系统没有 bash，无法执行官方安装脚本"
                echo "  解决方案：1) 使用预构建包模式 2) 安装 busybox 完整版含 bash"
                exit 1
            fi
        fi

        # ===== 关键：处理 /www 只读问题（只调用一次，缓存结果）=====
        local www_ok=0
        if ensure_www_writable; then
            echo "[OK] /www 可写，使用标准路径"
            www_ok=1
        else
            echo "[WARN] /www 不可写，将 patch 安装脚本使用 /data/btpanel"
        fi

        # ===== 关键：准备 Android 环境（/tmp、HOME、/etc/）=====
        prepare_android_env
        echo "[OK] Android 环境准备完成 (HOME=$HOME, /tmp=$( [ -w /tmp ] && echo 'writable' || echo 'NOWRITE' ))"

        echo "下载 install_panel.sh..."
        local install_script="/data/local/tmp/bt_install_panel.sh"
        if ! download_file "https://download.bt.cn/install/install_panel.sh" "$install_script"; then
            echo "[FATAL] 下载安装脚本失败（DNS 解析失败？网络未就绪？）"
            echo "  检查：ping download.bt.cn 是否能解析"
            exit 2
        fi
        # 验证下载的脚本是有效的（非空 + 至少 1000 字节 + 首行是 #!）
        local script_size
        script_size=$(wc -c < "$install_script" 2>/dev/null || echo 0)
        if [ "$script_size" -lt 1000 ] 2>/dev/null; then
            echo "[FATAL] 下载的安装脚本异常：文件大小 ${script_size} 字节（期望 >1000）"
            rm -f "$install_script"
            exit 2
        fi
        local first_line
        first_line=$(head -n 1 "$install_script" 2>/dev/null)
        if ! echo "$first_line" | grep -q '^#!'; then
            echo "[FATAL] 下载的安装脚本首行不是 shebang：$first_line"
            rm -f "$install_script"
            exit 2
        fi
        chmod 0755 "$install_script"

        # 如果 /www 不可写，patch 安装脚本使用 /data/btpanel（用缓存结果，不再重复调用）
        if [ $www_ok -eq 0 ]; then
            patch_install_script_for_data "$install_script"
            echo "[OK] 安装脚本已 patch: /www → /data/btpanel, /usr/bin/bt → /data/btpanel/bt"
        fi
        # 无论如何都做 Android 兼容 patch（/tmp、/etc/hostname 等）
        patch_install_script_for_android "$install_script"

        echo "执行安装（3-10 分钟）..."
        echo "  使用解释器: $SH_BIN"
        echo "  HOME=$HOME  /tmp=$( [ -w /tmp ] && echo 'OK' || echo 'FAIL' )"
        # 用 bash 执行脚本（install_panel.sh 使用 bash 语法）
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
            # 关键：必须 exit 非零，否则 overall_rc=0 → 失败日志不创建
            exit 1
        fi
    } >> "${INSTALL_LOG}" 2>&1

    local overall_rc=$?
    # 即使 overall_rc=0（如 exit 0 被跳过），也检查实际安装状态
    if ! is_btpanel_installed; then
        overall_rc=1
    fi
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
        # 后台执行安装，带重试逻辑（最多 3 次，间隔 30 秒）
        # 注意：subshell 内不用 local（POSIX sh 中 local 只在函数内有效）
        (
            retry=0; max_retry=3
            while [ $retry -lt $max_retry ]; do
                auto_install_btpanel
                is_btpanel_installed && break
                retry=$((retry + 1))
                if [ $retry -lt $max_retry ]; then
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 安装失败，第 ${retry} 次重试（共 ${max_retry} 次），30 秒后重试..." >> "$INSTALL_LOG" 2>/dev/null
                    sleep 30
                fi
            done
        ) &
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
        # 安装放在后台，带重试逻辑（最多 3 次，间隔 30 秒）
        # 注意：subshell 内不用 local（POSIX sh 中 local 只在函数内有效）
        (
            retry=0; max_retry=3
            while [ $retry -lt $max_retry ]; do
                auto_install_btpanel
                is_btpanel_installed && break
                retry=$((retry + 1))
                if [ $retry -lt $max_retry ]; then
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 安装失败，第 ${retry} 次重试（共 ${max_retry} 次），30 秒后重试..." >> "$INSTALL_LOG" 2>/dev/null
                    sleep 30
                fi
            done
        ) &
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
