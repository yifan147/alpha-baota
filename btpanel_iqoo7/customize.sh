#!/system/bin/sh
#
# iQOO 7 宝塔面板开机自启模块 - 安装脚本
#

# 设置权限
set_perm_recursive $MODPATH/system/bin 0 0 0755 0755

# ========== 安装前预检：检测宝塔面板是否已存在 ==========
BTPANEL_INSTALL_DIR="/data/btpanel"
bt_bin=""
found_installed=0
found_residue=0

for p in \
    /www/server/panel/bt \
    /data/btpanel/bt \
    /data/adb/btpanel/bt \
    /data/btpanel/panel/bt \
    /data/linux/bt \
    /data/linux/www/server/panel/bt \
    /usr/bin/bt
do
    if [ -f "$p" ] && [ -x "$p" ]; then
        bt_bin="$p"
        break
    fi
done
if [ -z "$bt_bin" ]; then
    alt=$(command -v bt 2>/dev/null)
    if [ -n "$alt" ] && [ -f "$alt" ]; then bt_bin="$alt"; fi
fi

# 检查核心文件是否存在（避免把残留目录误判为已安装）
panel_core_ok=0
if [ -d "/www/server/panel" ] && [ -f "/www/server/panel/class/panelPlugin.py" ]; then
    panel_core_ok=1
fi
if [ -d "/data/btpanel/panel" ] && [ -f "/data/btpanel/panel/class/panelPlugin.py" ]; then
    panel_core_ok=1
fi
if [ -d "/data/adb/btpanel/panel" ] && [ -f "/data/adb/btpanel/panel/class/panelPlugin.py" ]; then
    panel_core_ok=1
fi
if [ -d "/data/linux/www/server/panel" ] && [ -f "/data/linux/www/server/panel/class/panelPlugin.py" ]; then
    panel_core_ok=1
fi

if [ -n "$bt_bin" ] && [ $panel_core_ok -eq 1 ]; then
    found_installed=1
elif [ -d "/www/server/panel" ] || [ -d "/data/btpanel/panel" ]; then
    # 有目录但核心缺失 → 判定为残留
    found_residue=1
fi

ui_print ""
ui_print "  iQOO 7 宝塔面板自动安装+开机自启"
ui_print "  ==================================="
ui_print ""
ui_print "  ✅ 模块已安装成功！"
ui_print ""
if [ $found_installed -eq 1 ]; then
    ui_print "  ✔ 检测到已有宝塔面板安装"
    ui_print "    路径: $bt_bin"
    ui_print "    已跳过自动安装，重启后直接启动服务"
elif [ $found_residue -eq 1 ]; then
    ui_print "  ⚠ 检测到宝塔面板残留目录（未完整安装）"
    ui_print "    重启后将自动清理残留并重新安装"
else
    ui_print "  ✘ 未检测到宝塔面板"
    ui_print "    重启并联网后将自动下载安装（3-10分钟）"
fi
ui_print ""
ui_print "  功能说明:"
ui_print "  ├ 首次开机联网后自动安装宝塔面板"
ui_print "  ├ 安装完成后自动启动面板服务"
ui_print "  ├ 后续每次开机自动启动面板"
ui_print "  ├ 面板默认账号: admin"
ui_print "  └ 面板默认密码: admin"
ui_print ""
ui_print "  使用提示:"
ui_print "  • 重启设备并连接网络"
ui_print "  • 终端执行: btpanel status 查看状态"
ui_print "  • 终端执行: btpanel install 手动重装"
ui_print "  • 安装日志: /data/btpanel/install.log"
ui_print ""

# 创建标志文件
touch $MODPATH/installed

# 确保标志目录提前创建（首次启动无额外延时）
mkdir -p /data/btpanel/.module_flags 2>/dev/null || true