# alpha-baota - iQOO 7 宝塔面板自动安装 + 开机自启 Magisk 模块

专为 **iQOO 7** 设备定制的宝塔面板 Magisk 模块，实现自动安装与开机自启动。

---

## 功能特性

| 功能 | 说明 |
|------|------|
| **自动安装** | 首次开机联网后自动下载安装宝塔面板，无需手动操作 |
| **开机自启** | 安装完成后，每次开机自动运行宝塔面板服务 |
| **状态监控** | 实时检测面板运行状态，在 Magisk 管理器的模块描述中动态显示 |
| **IP 显示** | 自动获取并展示当前设备的局域网 IP，方便快速访问 |
| **默认账号密码** | 安装完成后自动将面板账号密码设置为 `admin` / `admin` |
| **管理命令** | 内置 `btpanel` 命令，支持状态查询、启停、重装、查看日志 |

---

## 下载

ZIP 模块包（直接刷入 Magisk 即可）：

**[btpanel_iqoo7.zip](https://github.com/yifan147/alpha-baota/releases/download/v2.0.0/btpanel_iqoo7.zip)**

也可以直接下载仓库内的 `btpanel_iqoo7.zip`。

---

## 安装方法

1. 在 Magisk 管理器中选择「模块」→「从本地安装」
2. 选择 `btpanel_iqoo7.zip`
3. 安装完成后重启设备
4. 确保设备连接到 WiFi/移动网络（首次安装需要联网下载）
5. 等待 3-10 分钟，模块会在后台自动安装宝塔面板

---

## 使用方式

终端（Termux 或 ADShell）中执行 `btpanel` 命令：

```bash
btpanel status    # 查看面板状态、访问地址、账号密码
btpanel start     # 启动面板
btpanel stop      # 停止面板
btpanel restart   # 重启面板
btpanel install   # 手动安装 / 重新安装宝塔面板
btpanel url       # 查看访问地址
btpanel log       # 查看安装日志
```

浏览器访问 `http://设备IP:8888`，使用以下默认信息登录：

- **账号**: `admin`
- **密码**: `admin`

安装日志路径: `/data/btpanel/install.log`

---

## 模块结构

```
btpanel_iqoo7/
├── module.prop                              # 模块元数据
├── service.sh                               # 开机自启 + 自动安装逻辑
├── customize.sh                             # Magisk 安装时执行的脚本
├── uninstall.sh                             # 卸载时清理脚本
├── system/
│   └── bin/
│       └── btpanel                          # btpanel 管理命令
└── META-INF/com/google/android/
    ├── update-binary                        # Magisk 安装器
    └── updater-script
```

---

## 工作流程

```
刷入模块 → 重启设备 → 等待系统启动 + 网络就绪
                                │
                        ┌───────┴───────┐
                        │               │
                  已安装宝塔      未安装宝塔
                        │               │
                  直接启动服务     下载官方安装脚本
                        │               │
                  每 5 分钟更新    执行安装 (3-10 分钟)
                  Magisk 描述中     │
                  显示状态+IP+地址   设置账号密码 admin/admin
                                    │
                              启动面板服务
                                    │
                              每 5 分钟更新
                              Magisk 描述中
                              显示状态+IP+地址
```

---

## 常见问题

**Q: 安装后多久面板才会启动？**
A: 首次开机联网后自动安装大约需要 3-10 分钟（取决于网速和设备性能）。可以执行 `btpanel log` 查看进度。

**Q: 访问地址显示 "无法获取"？**
A: 请确保已连接 WiFi 或移动网络，然后执行 `btpanel status` 刷新。

**Q: 面板安装失败怎么办？**
A: 查看日志 `btpanel log`，也可以执行 `btpanel install` 手动重新安装。

**Q: 默认账号密码不是 admin？**
A: 面板默认随机账号密码，模块会在安装完成后自动改为 `admin/admin`。如果失败，可执行 `bt 5` 修改密码，`bt 6` 修改用户名。

---

## 官方参考

- 宝塔面板官网: https://www.bt.cn/new/download.html
- 官方安装脚本: `curl -sSO https://download.bt.cn/install/install_panel.sh && bash install_panel.sh ed8484bec`
