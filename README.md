# alpha-baota - iQOO 7 宝塔面板自动安装 + 开机自启 Magisk 模块

专为 **iQOO 7** 设备定制的宝塔面板 Magisk 模块，**适配 Alpha Magisk (3400)、Magisk 原版、Magisk Delta、Kitsune Mask**。

安装前会自动检测已有宝塔：
- ✅ 已完整安装 → 跳过安装，直接启动服务
- ⚠ 存在残留目录 → 自动清理残留，再执行干净安装
- ❌ 未安装 → **刷入时若有网络立即开始安装**（装不完重启后自动续装）

---

## 最新版本

**v2.4.0** (2026-08-04) — 专对 **Alpha Magisk (3400)** 优化：

| 特性 | v2.3.0 | v2.4.0 |
|------|--------|--------|
| 刷入阶段自动安装宝塔 | ❌ | ✅ **有网立即装 + 续装标志兜底** |
| 模块介绍显示状态 | 启动中/运行中/停止中/未安装 4 种混乱状态 | ✅ **只显示「已启动 ▶」/「已关闭 ■」两种清晰态** |
| 音量键操作 | 菜单选择 + 确认 | ✅ **一按即切换，无需确认**<br>音量上 = 直接开启<br>音量下 = 直接关闭<br>电源键 = 退出 |
| 模块热开关（关/开模块） | 可能残留 BT-Panel 进程 | ✅ **每次关键节点检测 disable 文件，立即停服务 + 杀进程** |
| 安装失败日志保留 | 部分落盘 | ✅ **所有 stdout/stderr 全量落盘 + install.failed.log + crash.log 三份备份** |
| POSIX sh / busybox ash 兼容 | ⚠ 数组语法报错 | ✅ **全部改用字符串遍历，bash/sh/ash 全兼容** |
| keycheck 阻塞 | 无超时 → 可能卡死 | ✅ **timeout 包裹 + getevent /sys 节点三重兜底** |

---

## 功能特性

| 功能 | 说明 |
|------|------|
| **智能预检** | 安装模块时、开机启动时都会检测宝塔是否已存在 |
| **刷入即装** | customize.sh 阶段有网立即联网安装（最多等 480s），装不完写 `force_continue_install` 标志，service.sh 开机立刻续装 |
| **开机自启** | 安装完成后，每次开机自动运行宝塔面板服务 |
| **残留清理** | 自动识别并清理中断安装留下的空壳目录，避免状态错乱 |
| **状态监控** | 实时检测面板运行状态，在 Magisk 管理器的模块描述中动态显示「已启动 ▶」/「已关闭 ■」 |
| **IP 显示** | 自动获取并展示当前设备的局域网 IP，方便快速访问 |
| **默认账号密码** | 安装完成后自动将面板账号密码设置为 `admin` / `admin` |
| **音量键无菜单操作** | 点模块右下操作按钮 → 音量上直接开启、音量下直接关闭、电源键退出，无需选择确认 |
| **管理命令** | 内置 `btpanel` 命令：status/start/stop/restart/install/url/log |

---

## 下载

**方式 1（推荐）**：Release 资产直下 — 打开 [仓库 Releases](https://github.com/yifan147/alpha-baota/releases)，下载最新 `btpanel_iqoo7.zip`。

**方式 2（从 ZIP 源码构建）**：
```bash
git clone https://github.com/yifan147/alpha-baota
cd alpha-baota/btpanel_iqoo7
zip -r9 ../btpanel_iqoo7.zip META-INF module.prop customize.sh service.sh action.sh uninstall.sh system/bin/btpanel
```

---

## 安装方法

1. 在 Magisk 管理器中选择「模块」→「从本地安装」
2. 选择 `btpanel_iqoo7.zip`
3. 安装界面会立即显示：
   - ✔ **检测到已有宝塔面板安装** → 跳过自动安装，重启后直接启动
   - ⚠ **检测到宝塔面板残留目录** → 先清理残留，有网则立即开始安装
   - ↓ **刷入阶段立即安装宝塔面板...** → 已检测到网络，后台开始安装（最多等 480 秒）
   - ⚠ **刷入环境无网络，无法立即安装** → 已写续装标志，重启联网后 service.sh 立刻安装
4. **等待安装进度完成后再重启**（刷入阶段最多等 8 分钟）
5. 若 480s 内未装完，`force_continue_install` 标志会保留，**重启后联网立即自动续装**

---

## 使用方式

### 方式 A：音量键（推荐，Alpha Magisk 3400 适配）
点模块右下操作按钮 → 一按即切换：
- **音量上** = 直接开启宝塔面板
- **音量下** = 直接关闭宝塔面板
- **电源键** = 退出操作菜单
- 60 秒无操作自动退出

### 方式 B：终端命令（Termux / ADB Shell）
```bash
btpanel status    # 查看面板状态、访问地址、账号密码
btpanel start     # 启动面板
btpanel stop      # 停止面板
btpanel restart   # 重启面板
btpanel install   # 手动安装 / 重新安装（已装时会提示确认）
btpanel url       # 查看访问地址
btpanel log       # 查看安装日志
```

浏览器访问 `http://设备IP:8888`，使用以下默认信息登录：
- **账号**: `admin`
- **密码**: `admin`

### 日志位置
- 安装日志: `/data/btpanel/install.log`（所有 stdout/stderr 全量）
- 失败日志: `/data/btpanel/crash.log`（异常事件）
- 失败备份: `/data/btpanel/.module_flags/install.failed.log`
- 刷入续装标志: `/data/btpanel/.module_flags/force_continue_install`（存在 = 下次开机强制续装）

---

## 智能检测逻辑

```
刷入模块（customize.sh）
├─ 已完整安装（bt 可执行 + class/panelPlugin.py）→ 跳过，重启直接启动
├─ 残留目录（有目录但缺核心）→ 先清理残留
└─ 未安装
   ├─ 有网络 → 写 force_continue_install 标志
   │         → 后台开始安装（最多等 480 秒）
   │         ├─ 安装完成 → 清 force_continue_install 标志
   │         └─ 超时/失败 → 保留 force_continue_install，service.sh 续装
   └─ 无网络 → 写 force_continue_install 标志，重启后联网续装
```

```
开机启动（service.sh）
├─ 关键节点 1：检测 disable/remove/skip_mount → 直接跳过不启动
├─ 等待 boot_complete
├─ 关键节点 2：检测 disable → safe_cleanup_on_disable（停服务+杀进程）
├─ 强制续装标志 force_continue_install 检测（优先级最高）
│  ├─ YES → 立即清理残留 + 等网络 → auto_install_btpanel 续装
│  └─ NO  → 正常流程
│     ├─ 已安装 → 直接 start_btpanel
│     └─ 未安装 → 等网络 → auto_install_btpanel（带 INSTALL_LOCK 防重入）
├─ 关键节点 3：每次操作前再次检测 disable → safe_cleanup
└─ 每 5 分钟刷新一次 Magisk 模块描述（状态 + IP + 地址）
                ↑ 刷新前再次检测 disable → 立即安全退出
```

---

## 模块结构

```
btpanel_iqoo7/
├── module.prop                              # 模块元数据 (v2.4.0, versionCode=6)
├── service.sh                               # 开机自启 + 续装检测 + 热开关安全
├── customize.sh                             # 刷入阶段立即安装 + 续装标志
├── action.sh                                # 音量键无菜单操作（上=开 下=关）
├── uninstall.sh                             # 卸载时停服务 + 清理标志
├── system/
│   └── bin/
│       └── btpanel                          # btpanel 管理命令
└── META-INF/com/google/android/
    ├── update-binary                        # Magisk 安装器
    └── updater-script
```

---

## 常见问题

**Q: 刷入后显示「安装未在 480s 内完成，已写续装标志」？**
A: 正常。只要看到这句话，`force_continue_install` 标志就已经写入。重启设备并连上网，service.sh 会立刻检测到标志并继续安装，不需要任何手动操作。

**Q: 安装提示已检测到宝塔面板，但我不想保留旧的，想重装怎么办？**
A: 重启后执行 `btpanel install`，脚本会先显示当前安装路径，再询问是否重装；输入 `y` 确认即可。

**Q: 安装后多久面板才会启动？**
A:
- 已完整安装 → 重启后 1-2 分钟内自动启动
- 刷入阶段自动安装 → 3-10 分钟（取决于网速和设备性能），可执行 `btpanel log` 看进度
- 续装阶段 → 联网后立刻开始，进度同上

**Q: 访问地址显示 "无法获取"？**
A: 请确保已连接 WiFi 或移动网络，然后执行 `btpanel status` 刷新。

**Q: 在 Magisk 管理器关了模块开关，但宝塔还在跑？**
A: 已修复 v2.4.0。service.sh 在 3 个关键节点（启动前、清理后、每 5 分钟刷新前）都会检测 disable/remove/skip_mount 文件，一旦出现立刻执行 `safe_cleanup_on_disable`：停止面板服务 → `pkill -f BT-Panel` + `pkill -f gunicorn.*panel` → 杀掉后代 sleep 进程 → 清状态文件 → 退出。关模块后最多 5 分钟内面板必停。

**Q: 点操作按钮按音量键没反应？**
A: 三种逐级兜底：
1. Alpha Magisk 3400 自带 `keycheck`（路径：`/data/adb/keycheck`、`/sbin/keycheck` 等 6 处搜索），用 `timeout` 包裹防卡死；
2. 找不到 keycheck 就用 `getevent -lc` 直接抓原始输入事件；
3. 前两种都失败就轮询 `/sys/class/input/key/vol_up` 等 /sys 节点。
仍然失败就执行终端命令 `btpanel start` / `btpanel stop`。

**Q: 默认账号密码不是 admin？**
A: 面板默认随机账号密码，模块会在安装完成后自动改为 `admin/admin`。若失败，可执行 `bt 5` 修改密码，`bt 6` 修改用户名。

---

## 官方参考

- 宝塔面板官网: https://www.bt.cn/new/download.html
- 官方安装脚本: `curl -sSO https://download.bt.cn/install/install_panel.sh && bash install_panel.sh ed8484bec`
- Alpha Magisk: https://github.com/Dr-TSNG/MagiskAlpha （3400 版本已完整适配）
