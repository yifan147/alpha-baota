#!/system/bin/sh
#
# iQOO 7 宝塔面板 - post-fs-data.sh
# 在 post-fs-data 阶段（开机早期）设置 /www 为可写目录
# Android 根文件系统通常只读 → 需要创建 /www 并 bind mount 到 /data
#

BTPANEL_DATA_DIR="/data/btpanel"
BTPANEL_WWW_DATA="${BTPANEL_DATA_DIR}/www_data"

mkdir -p "$BTPANEL_WWW_DATA" 2>/dev/null

# 方法 1：直接创建 /www（部分设备 rootfs 可写）
mkdir -p /www 2>/dev/null

# 方法 2：remount / 为 rw，创建 /www，再 remount 为 ro
if [ ! -d /www ]; then
    mount -o remount,rw / 2>/dev/null
    mkdir -p /www 2>/dev/null
    mount -o remount,ro / 2>/dev/null
fi

# 方法 3：如果 /www 还是没创建成功，尝试用 tmpfs（仅限已存在 /www 的情况）
if [ ! -d /www ]; then
    # 某些 Android / 下可以 mkdir 但默认 ro → 再试一次 remount
    mount -o remount,rw / 2>/dev/null
    mkdir -p /www 2>/dev/null
    # 不 remount 回 ro，保持 rw 让后续操作能写
fi

# 如果 /www 存在，bind mount 到数据目录（持久化到 /data，重启不丢）
if [ -d /www ]; then
    # 确保目录非空或刚创建都可以 bind
    mount --bind "$BTPANEL_WWW_DATA" /www 2>/dev/null || true
    # 验证 bind 是否成功
    if [ -w /www ]; then
        echo "[post-fs-data] /www bind mount 成功 → $BTPANEL_WWW_DATA" > "$BTPANEL_DATA_DIR/.module_flags/www_mount_status" 2>/dev/null
    else
        echo "[post-fs-data] /www bind mount 失败" > "$BTPANEL_DATA_DIR/.module_flags/www_mount_status" 2>/dev/null
    fi
else
    echo "[post-fs-data] /www 创建失败，将 fallback 到 /data/btpanel" > "$BTPANEL_DATA_DIR/.module_flags/www_mount_status" 2>/dev/null
fi
