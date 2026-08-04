# alpha-baota - iQOO 7 宝塔面板自动安装 + 开机自启 Magisk 模块

专为 **iQOO 7** 设备定制的宝塔面板 Magisk 模块，**安装前会自动检测已有宝塔**：
- ✅ 已完整安装 → 跳过安装，直接启动服务
- ⚠ 存在残留目录 → 自动清理残留，再执行干净安装
- ❌ 未安装 → 联网后自动下载安装

---

## 功能特性

| 功能 | 说明 |
|------|------|
| **智能预检** | 安装模块时、开机启动时都会检测宝塔是否已存在 |
| **自动安装** | 首次开机联网后自动下载安装宝塔面板，无需手动操作 |
| **开机自启** | 安装完成后，每次开机自动运行宝塔面板服务 |
| **残留清理** | 自动识别并清理中断安装留下的空壳目录，避免状态错乱 |
| **状态监控** | 实时检测面板运行状态，在 Magisk 管理器的模块描述中动态显示 |
| **IP 显示** | 自动获取并展示当前设备的局域网 IP，方便快速访问 |
| **默认账号密码** | 安装完成后自动将面板账号密码设置为 `admin` / `admin` |
| **管理命令** | 内置 `btpanel` 命令：status/start/stop/restart/install/url/log |

---

## 下载

**方式 1（推荐）**：用仓库里的解码脚本生成 ZIP，确保完整性：
```bash
git clone https://github.com/yifan147/alpha-baota
cd alpha-baota
bash build_zip.sh   # 生成 btpanel_iqoo7.zip
```

**方式 2（手动 base64 解码）**：
```bash
# macOS / Linux / Termux
base64 -d btpanel_iqoo7.zip.b64 > btpanel_iqoo7.zip

# Windows PowerShell
certutil -decode btpanel_iqoo7.zip.b64 btpanel_iqoo7.zip
```

**方式 3（Release 资产）**：打开仓库 Releases，下载 `btpanel_iqoo7.zip`。

---

## 安装方法

1. 在 Magisk 管理器中选择「模块」→「从本地安装」
2. 选择 `btpanel_iqoo7.zip`
3. 安装界面会立即显示：
   - ✔ **检测到已有宝塔面板安装** → 已跳过自动安装，重启后直接启动
   - ⚠ **检测到宝塔面板残留目录** → 重启后将自动清理残留并重新安装
   - ✘ **未检测到宝塔面板** → 重启并联网后自动下载安装（3-10分钟）
4. 重启设备
5. 确保设备连接到 WiFi/移动网络（自动安装需要联网）

---

## 使用方式

终端（Termux 或 ADShell）中执行 `btpanel` 命令：

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

安装日志路径: `/data/btpanel/install.log`

---

## 智能检测逻辑

```
刷入模块（安装阶段）
├─ 存在 bt 可执行文件 + 面板核心 class/panelPlugin.py
│  └─ → 判定为「已完整安装」，跳过安装，重启后直接启动服务
├─ 有 /www/server/panel 目录但缺核心文件
│  └─ → 判定为「残留目录」，重启时先自动清理，再执行干净安装
└─ 两者都没有
   └─ → 判定为「未安装」，联网后自动安装
```

```
开机启动（service.sh）
├─ 先做残留检测 + 清理（仅在判定为残留时执行）
├─ 二次检测：is_btpanel_installed
│  ├─ YES → 直接 start_btpanel，不下载安装脚本
│  └─ NO  → 等网络 → 启动 auto_install_btpanel（带锁，防多实例冲突）
└─ 每 5 分钟刷新一次 Magisk 模块描述（状态 + IP + 地址）
```

---

## 模块结构

```
btpanel_iqoo7/
├── module.prop                              # 模块元数据 (v2.1.0)
├── service.sh                               # 开机自启 + 检测逻辑 + 自动安装
├── customize.sh                             # 模块安装时预检（已装/残留/未装）
├── uninstall.sh                             # 卸载时清理
├── system/
│   └── bin/
│       └── btpanel                          # btpanel 管理命令
└── META-INF/com/google/android/
    ├── update-binary                        # Magisk 安装器
    └── updater-script
```

---

## 常见问题

**Q: 安装提示已检测到宝塔面板，但我不想保留旧的，想重装怎么办？**
A: 重启后执行 `btpanel install`，脚本会先显示当前安装路径，再询问是否重装；输入 `y` 确认即可。

**Q: 安装后多久面板才会启动？**
A:
- 已完整安装 → 重启后 1-2 分钟内自动启动
- 自动安装 → 联网后 3-10 分钟（取决于网速和设备性能），可执行 `btpanel log` 看进度

**Q: 访问地址显示 "无法获取"？**
A: 请确保已连接 WiFi 或移动网络，然后执行 `btpanel status` 刷新。

**Q: 面板安装失败怎么办？**
A: 查看日志 `btpanel log`，也可以执行 `btpanel install` 手动重新安装。

**Q: 默认账号密码不是 admin？**
A: 面板默认随机账号密码，模块会在安装完成后自动改为 `admin/admin`。若失败，可执行 `bt 5` 修改密码，`bt 6` 修改用户名。

---

## 官方参考

- 宝塔面板官网: https://www.bt.cn/new/download.html
- 官方安装脚本: `curl -sSO https://download.bt.cn/install/install_panel.sh && bash install_panel.sh ed8484bec`
