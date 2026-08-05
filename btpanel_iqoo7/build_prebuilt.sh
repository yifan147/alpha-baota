#!/system/bin/sh
#
# iQOO 7 宝塔面板 - 预构建打包脚本
# 用法：在已经成功安装宝塔面板的手机上运行一次：
#   su -c sh /data/adb/modules/btpanel_iqoo7/build_prebuilt.sh
# 会把完整宝塔打包到 /sdcard/btpanel_prebuilt_arm64.tar.gz（约 800MB~1.5GB）
# 下次刷模块时，如果检测到这个 tarball，会直接解包跳过安装脚本（10 秒完成）
#
# 打包内容：
#   - /www/server/panel  (面板核心 + Python环境 + Nginx + MySQL + PHP)
#   - /www/wwwroot       (站点根目录)
#   - /www/backup        (备份)
#   - /www/wwwlogs       (日志)
#   - /data/btpanel      (模块侧 fallback 路径)
#   - /usr/bin/bt        (bt 命令 - 如存在)
#   - /etc/init.d/bt     (bt 服务脚本 - 如存在)

BTPANEL_INSTALL_DIR="/data/btpanel"
BTPANEL_FLAG_DIR="${BTPANEL_INSTALL_DIR}/.module_flags"
OUT_TGZ="/sdcard/btpanel_prebuilt_arm64.tar.gz"
TMP_LIST="/data/local/tmp/bt_prebuilt_list.txt"

echo "============================================"
echo " iQOO 7 宝塔面板预构建打包工具"
echo "============================================"
echo ""

# 1. 检查是否真的已安装
echo "[1/6] 检测宝塔是否已完整安装..."
INSTALLED=0
for d in /www/server/panel /data/btpanel/server/panel; do
    if [ -d "$d" ] && [ -f "$d/class/panelPlugin.py" ]; then
        INSTALLED=1; echo "  OK: 检测到面板核心: $d"
    fi
done
if [ "$INSTALLED" != "1" ]; then
    echo "  ❌ 未检测到完整的宝塔面板安装，先安装好再打包"
    echo "  请先运行: btpanel install"
    exit 1
fi

# 2. 检查存储可用空间
echo "[2/6] 检查 /sdcard 可用空间..."
FREE_BYTES=$(df -k /sdcard 2>/dev/null | tail -n 1 | awk '{print $4}')
FREE_BYTES=${FREE_BYTES:-0}
FREE_MB=$((FREE_BYTES / 1024))
echo "  可用空间: ${FREE_MB} MB"
if [ "$FREE_MB" -lt 2000 ] 2>/dev/null; then
    echo "  ⚠ 可用空间 < 2GB，可能不够！继续打包风险自负"
fi

# 3. 收集要打包的路径（注意：打包整个 /www/server，包含 nginx/mysql/php，不只是 panel）
echo "[3/6] 收集打包路径..."
> "$TMP_LIST"
for dir in \
    /www/server \
    /www/wwwroot \
    /www/backup \
    /www/wwwlogs \
    /data/btpanel/server \
    /data/btpanel/wwwroot \
    /data/btpanel/bt \
    /data/btpanel/init.d; do
    if [ -d "$dir" ] || [ -f "$dir" ] || [ -L "$dir" ]; then
        echo "$dir" >> "$TMP_LIST"
        echo "  + $dir"
    fi
done
# 系统级配置和 init 脚本
for f in /usr/bin/bt /etc/init.d/bt /etc/init.d/nginx /etc/init.d/mysqld \
         /etc/init.d/httpd /etc/my.cnf /root/.my.cnf /root/.bt.cnf; do
    if [ -f "$f" ] || [ -L "$f" ]; then
        echo "$f" >> "$TMP_LIST"
        echo "  + $f"
    fi
done
FILE_COUNT=$(wc -l < "$TMP_LIST")
echo "  共收集 $FILE_COUNT 个路径"

# 4. 停面板（确保数据一致性）
echo "[4/6] 先停止宝塔面板，确保打包时数据一致..."
BT_BIN=""
for p in /www/server/panel/bt /data/btpanel/bt /data/btpanel/server/panel/bt /usr/bin/bt; do
    [ -f "$p" ] && [ -x "$p" ] && BT_BIN="$p" && break
done
if [ -n "$BT_BIN" ]; then
    echo "  执行: $BT_BIN stop"
    export BT_IGNORE=1
    "$BT_BIN" stop >/dev/null 2>&1 || true
    sleep 3
    pkill -9 -f "BT-Panel" >/dev/null 2>&1 || true
    pkill -9 -f "gunicorn.*panel" >/dev/null 2>&1 || true
    echo "  OK"
fi

# 5. 打包
echo "[5/6] 开始打包 → $OUT_TGZ ..."
echo "  这一步比较慢（5~15 分钟），请耐心等待..."

START_T=$(date +%s)

# ===== busybox tar 兼容检测 =====
# GNU tar: 支持 --ignore-failed-read 和 -T
# busybox tar: 通常不支持长选项，也不支持 -T（从文件读取路径列表）
# 检测策略：先试 GNU tar 全套参数；失败就 fallback 到 busybox 基础模式
TAR_LOG="/data/local/tmp/bt_prebuilt_tar.log"
> "$TAR_LOG"

# 构造要打包的路径列表（shell 变量，不用 -T）
TAR_PATHS=""
while IFS= read -r p; do
    [ -n "$p" ] && TAR_PATHS="$TAR_PATHS $p"
done < "$TMP_LIST"

TAR_RC=0
# 方案 1：GNU tar + 全套选项
if tar --ignore-failed-read -cpz -f "$OUT_TGZ" -T "$TMP_LIST" >> "$TAR_LOG" 2>&1; then
    echo "  使用 GNU tar (带 --ignore-failed-read + -T)"
elif tar -cpz -f "$OUT_TGZ" $TAR_PATHS >> "$TAR_LOG" 2>&1; then
    # 方案 2：busybox tar 带 gzip (-z)，直接传路径
    echo "  使用 busybox tar (带 -z，直接传路径)"
elif command -v gzip >/dev/null 2>&1; then
    # 方案 3：tar 不带 z，先打未压缩 tar，再 gzip
    UNCOMP_TAR="/data/local/tmp/btpanel_prebuilt_uncompressed.tar"
    rm -f "$UNCOMP_TAR"
    echo "  tar 无 -z，先 tar cp 再 gzip..."
    if tar -cpf "$UNCOMP_TAR" $TAR_PATHS >> "$TAR_LOG" 2>&1; then
        gzip -c "$UNCOMP_TAR" > "$OUT_TGZ" 2>>"$TAR_LOG"
        TAR_RC=$?
        rm -f "$UNCOMP_TAR"
        echo "  使用 tar cp + gzip -c 两步完成"
    else
        TAR_RC=99
        echo "  tar cp 也失败了"
    fi
else
    echo "  tar -z 失败且无 gzip 可用，尽力尝试 tar cpzf..."
    tar -cpzf "$OUT_TGZ" $TAR_PATHS >> "$TAR_LOG" 2>&1 || TAR_RC=$?
fi

END_T=$(date +%s)
DURATION=$((END_T - START_T))

# 6. 校验
echo "[6/6] 校验输出文件..."
if [ -f "$OUT_TGZ" ] && [ -s "$OUT_TGZ" ]; then
    SIZE_BYTES=$(wc -c < "$OUT_TGZ")
    # 确保 SIZE_BYTES 是有效数字
    case "$SIZE_BYTES" in
        ''|*[!0-9]*) SIZE_BYTES=0 ;;
    esac
    SIZE_MB=$((SIZE_BYTES / 1048576))
    # 额外校验：tarball 至少 100MB，否则算失败
    if [ "$SIZE_BYTES" -lt 104857600 ]; then
        echo "  ❌ 打包异常：文件过小（${SIZE_MB} MB < 100MB），内容不全"
        echo "  检查 tar log: /data/local/tmp/bt_prebuilt_tar.log"
        [ -f "$TAR_LOG" ] && tail -n 30 "$TAR_LOG"
        exit 2
    fi
    echo "  ✅ 打包成功！"
    echo "  文件: $OUT_TGZ"
    echo "  大小: ${SIZE_MB} MB"
    echo "  耗时: ${DURATION} 秒"
    echo ""
    echo "  使用方法："
    echo "    1. 下次刷入模块前，确保这个文件在 /sdcard/ 下"
    echo "    2. 刷入 btpanel_iqoo7.zip → 模块会自动检测到预构建包"
    echo "    3. 直接解包（<10 秒）→ 开机直接启动，无需联网安装"

    # 写一个 meta 到 tarball 同目录（解包时校验版本兼容）
    META="${OUT_TGZ}.meta"
    {
        echo "btpanel_prebuilt_version=1.0"
        echo "built_at=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "arch=aarch64/arm64"
        echo "device_model=$(getprop ro.product.model 2>/dev/null || echo iQOO7)"
        echo "size_bytes=$SIZE_BYTES"
        echo "unpack_min_size_mb=100"
    } > "$META" 2>/dev/null
else
    echo "  ❌ 打包失败！检查 tar log: /data/local/tmp/bt_prebuilt_tar.log"
    [ -f "$TAR_LOG" ] && tail -n 30 "$TAR_LOG"
    exit 2
fi

# 重新启动面板
if [ -n "$BT_BIN" ]; then
    echo ""
    echo "  正在重新启动宝塔面板..."
    export BT_IGNORE=1
    nohup "$BT_BIN" start >/dev/null 2>&1 &
fi

rm -f "$TMP_LIST"

echo ""
echo "✅ 完成！预构建包已准备好，下次刷机直接用"
exit 0
