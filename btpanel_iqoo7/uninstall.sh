#!/system/bin/sh
#
# iQOO 7 宝塔面板开机自启模块 - 卸载脚本
#

# 1. 杀掉 service.sh 启动的所有后台进程
pkill -f "btpanel_iqoo7/service.sh" 2>/dev/null || true
pkill -f "update_module_desc" 2>/dev/null || true

# 2. 停止面板服务（搜索全部可能路径）
BTPANEL_BIN=""
for p in /www/server/panel/bt /data/btpanel/bt /data/btpanel/server/panel/bt \
         /data/adb/btpanel/bt /data/btpanel/panel/bt /usr/bin/bt; do
    if [ -f "$p" ] && [ -x "$p" ]; then
        BTPANEL_BIN="$p"
        break
    fi
done

if [ -n "$BTPANEL_BIN" ]; then
    export BT_IGNORE=1
    "$BTPANEL_BIN" stop >/dev/null 2>&1 || true
fi

# 3. 强制清理面板进程
sleep 1
pkill -f "BT-Panel" 2>/dev/null || true
pkill -f "gunicorn.*panel" 2>/dev/null || true

# 4. 卸载 /www 的 bind mount（如果存在）
if mountpoint -q /www 2>/dev/null; then
    umount /www 2>/dev/null || true
fi

# 5. 清理模块标志目录、安装锁、PID 文件
rm -rf /data/btpanel/.module_flags 2>/dev/null || true
rm -f /data/btpanel/bt.pid 2>/dev/null || true

# 6. 清理临时文件
rm -f /data/local/tmp/bt_install_panel.sh 2>/dev/null || true
rm -f /data/local/tmp/bt_prebuilt_list.txt 2>/dev/null || true
rm -f /data/local/tmp/bt_prebuilt_tar.log 2>/dev/null || true
rm -f /data/local/tmp/btpanel_prebuilt_uncompressed.tar 2>/dev/null || true
rm -f /data/local/tmp/.bt_getevent_tmp 2>/dev/null || true

echo "iQOO 7 宝塔面板开机自启模块已卸载"
echo "  - 模块后台进程已清理"
echo "  - 面板服务已停止"
echo "  - bind mount 已卸载"
echo "  - 临时文件已清理"
echo ""
echo "宝塔面板本身未被卸载，如需卸载请执行: bt uninstall"
echo "预构建包 /sdcard/btpanel_prebuilt_arm64.tar.gz 未删除（约 1GB），如不需要请手动删除"
