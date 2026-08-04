#!/system/bin/sh
#
# iQOO 7 宝塔面板开机自启模块 - 卸载脚本
#

# 停止面板服务
BTPANEL_BIN=""
for p in /data/btpanel/bt /data/adb/btpanel/bt /data/btpanel/panel/bt /www/server/panel/bt; do
    if [ -f "$p" ] && [ -x "$p" ]; then
        BTPANEL_BIN="$p"
        break
    fi
done

if [ -n "$BTPANEL_BIN" ]; then
    $BTPANEL_BIN stop >/dev/null 2>&1
fi

# 清理 PID 文件
rm -f /data/btpanel/bt.pid 2>/dev/null

echo "iQOO 7 宝塔面板开机自启模块已卸载"
echo "宝塔面板服务已停止"
