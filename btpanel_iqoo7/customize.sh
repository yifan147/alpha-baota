#!/system/bin/sh
#
# iQOO 7 宝塔面板开机自启模块 - 安装脚本
#

# 设置权限
set_perm_recursive $MODPATH/system/bin 0 0 0755 0755

# 安装完成后提示
ui_print ""
ui_print "  iQOO 7 宝塔面板自动安装+开机自启"
ui_print "  ==================================="
ui_print ""
ui_print "  ✅ 模块已安装成功！"
ui_print ""
ui_print "  功能说明:"
ui_print "  ├ 首次开机联网后自动安装宝塔面板"
ui_print "  ├ 安装完成后自动启动面板服务"
ui_print "  ├ 后续每次开机自动启动面板"
ui_print "  ├ 面板默认账号: admin"
ui_print "  └ 面板默认密码: admin"
ui_print ""
ui_print "  自动安装流程:"
ui_print "  1. 重启设备并连接网络"
ui_print "  2. 模块自动下载安装脚本（约3-10分钟）"
ui_print "  3. 安装完成后自动启动面板"
ui_print "  4. 终端执行: btpanel status 查看状态"
ui_print ""
ui_print "  安装日志: /data/btpanel/install.log"
ui_print ""

# 创建标志文件
touch $MODPATH/installed
