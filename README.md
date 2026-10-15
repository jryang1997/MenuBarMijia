# MenuBarMijia · 米家控制中心 (macOS)

一款基于 **Swift 6 + SwiftUI** 原生构建的 macOS 菜单栏智能家居控制中心。通过局域网 **Home Assistant WebSocket + REST** 实时联动小米官方 [`xiaomi_home`](https://github.com/Xiaomi/ha_xiaomi_home) 与美的 [`midea_ac_lan`](https://github.com/wuwentao/midea_ac_lan) 生态设备，将零散的 Home Assistant 实体自动聚合成高颜值、零延迟的 macOS 原生控制面板。

<p align="left">
  <img src="https://img.shields.io/badge/Platform-macOS%2015%2B-000000?logo=apple" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white" alt="Swift 6.0">
  <img src="https://img.shields.io/badge/Dependencies-Zero-brightgreen" alt="Zero Dependencies">
  <img src="https://img.shields.io/badge/License-MIT-blue" alt="MIT License">
</p>

---

## ✨ 为什么做这个项目？

市面上针对米家或 Home Assistant 的 macOS 菜单栏工具通常存在两类痛点：
1. **直连米家云 / miIO 类工具**：受限于小米未公开 MIoT-Spec 的设备，且无法跨品牌整合（例如家里同时有米家全屋设备 + 美的空调）。
2. **传统 Home Assistant 菜单栏客户端**：直接把 HA 里的原始 `entity` 逐条平铺出来——一个智能插座拆出开关、指示灯、童锁、实时功率、今日电量 5 个条目，一个小爱音箱拆出十几个实体，难以直接作为日常控制面板使用。

**MenuBarMijia** 采用 **「局域网 Home Assistant 桥接 + 智能多实体聚合引擎 (`DeviceSynthesizer`)」** 方案：
- **多实体自动聚合成「真设备」**：自动读取 HA 的 Area / Device / Entity 注册表，把同一物理设备下的主开关、传感器、子模式、指示灯合并为一张清爽的交互卡片，并自动剔除网关指示灯、DLNA 虚拟映射等噪音实体。
- **WebSocket 毫秒级双向同步 + 乐观 UI**：长连接监听 `state_changed` 事件（含 25 秒心跳保活与指数退避重连）；点击开关立即反馈，280ms 滑块防抖调节，指令失败自动回滚。
- **一键全关 + 5 秒悬浮撤销**：出门或睡前点击右上角「全关」，立即关闭全屋开启中的灯具、空调、电暖器、风扇与插座，并提供 5 秒内一键恢复原状的悬浮撤销条。
- **全品类深度抽屉控制**：
  - 💡 **灯光**：1%~100% 亮度滑块、2700K~6500K 色温滑块、日光/月光等情景模式切换。
  - ❄️ **空调 / 踢脚线电暖器**：目标温度步进调节、室温实时对照、制冷/制热/除湿/送风模式切换。
  - 🌀 **智能风扇**：开关与预设风速模式一键切换。
  - 🔌 **智能插座**：开关控制、实时功率 (W) 与今日用电量 (kWh) 监控、实体按键童锁开关。
  - 🧊 **互联网冰箱**：冷藏室 / 冷冻室实测温度显示与目标温度独立调节，支持智能/速冷/速冻/假日模式。
  - 🤖 **扫地机器人**：清扫状态与电量显示，支持开始清扫、暂停、回充指令。
  - 🔊 **小爱音箱**：音量调节、麦克风静音切换、一键放歌/停闹钟，并内置**小爱文字指令与 TTS 语音播报输入框**（可在 Mac 上直接打字让小爱播报或静默执行指令）。
  - 🌡️ **温湿度计 & 智能门锁**：顶部胶囊实时汇总各房间温湿度，菜单栏图标旁支持常驻显示主卧/阳台温度或当前开启设备数。
- **附带群晖 NAS 一键部署脚本**：内置 [`nas/deploy_ha.sh`](nas/deploy_ha.sh)，支持通过 SSH 一键在群晖 NAS (Container Manager / Docker) 上部署 Home Assistant 并预装 `xiaomi_home` 与 `midea_ac_lan` 集成。

---

## 🏗️ 项目结构

纯 Swift Package Manager 工程，**零第三方依赖**，严格启用 Swift 6 并发安全检查 (`swiftLanguageMode(.v6)`)：

```text
├── Package.swift
├── Sources/
│   ├── MijiaCore/                  # 核心领域与通信层（独立可测试库）
│   │   ├── Models.swift            # 统一设备值类型模型 (SmartDevice, DeviceKind, DeviceCommand)
│   │   ├── DeviceSynthesizer.swift # 多实体智能聚合、房间排序与噪音过滤引擎
│   │   ├── HomeProvider.swift      # HA WebSocket 实时流 + REST 服务调用 + MockProvider
│   │   ├── HomeStore.swift         # @Observable 主状态管理、乐观锁、280ms 防抖与全关撤销
│   │   └── KeychainAndPrefs.swift  # macOS 钥匙串 (Security) 令牌存储与偏好项
│   └── MenuBarMijiaApp/            # SwiftUI + AppKit 菜单栏视图层
│       ├── MenuBarMijiaApp.swift   # MenuBarExtra 窗口入口
│       ├── ControlCenterPanel.swift# 主控制中心面板、环境胶囊、房间筛选栏与悬浮通知
│       ├── DeviceCardView.swift    # 8 大品类可展开抽屉式设备卡片
│       ├── SettingsSheetView.swift # 面板标题、菜单栏显示模式、开机自启与 HA 连接配置
│       └── ThemeAndMotion.swift    # Apple 风格毛玻璃材质 (glassTile) 与阻尼弹簧曲线
├── Tests/
│   └── MijiaCoreTests/             # Swift Testing 单元测试（聚合逻辑、乐观更新与全关撤销）
├── scripts/
│   └── build_app.sh                # 一键编译 Release 并打包签名「米家控制中心.app」
└── nas/
    ├── deploy_ha.sh                # 群晖 NAS 一键部署 Home Assistant + 插件脚本
    ├── remote_setup.sh             # NAS 端容器初始化与国内镜像源自动回退脚本
    └── components/                 # 预打包的 xiaomi_home 与 midea_ac_lan 集成
```

---

## 🚀 快速开始

### 1. 准备 Home Assistant 后端

如果你已有运行中的 Home Assistant（并配置好了小米官方 `xiaomi_home` 集成）：
1. 登录你的 Home Assistant 网页端，点击左下角个人头像 -> **安全** -> 创建令牌，生成一个**长期访问令牌 (Long-Lived Access Token)**。

如果你有群晖 NAS（已安装 Container Manager）但尚未部署 Home Assistant，可直接运行仓库自带的一键部署脚本：
```bash
bash nas/deploy_ha.sh
```
按提示输入群晖局域网 IP 和管理员账号，脚本会自动拉取镜像、配置 `--network host` 并放入米家与美的局域网集成。

### 2. 编译并打包 macOS 应用

环境要求：**macOS 15.0 (Sequoia)+**、**Xcode 16 / Swift 6.0+**。

```bash
# 运行单元测试
swift test

# 编译 Release 版本并生成原生「米家控制中心.app」
bash scripts/build_app.sh

# 启动应用（或将其拖入 /Applications 应用程序目录）
open "米家控制中心.app"
```

### 3. 连接配置

1. 启动后点击屏幕右上角菜单栏的 🏠 图标打开面板。
2. 点击右下角 ⚙️ **设置** 按钮（或首次启动点击「前往连接配置」）。
3. 填入你的 **Home Assistant 地址**（如 `http://192.168.1.100:8123`）和 **长期访问令牌**（令牌将通过 macOS `Security` 框架安全保存在系统钥匙串中）。
4. 点击 **保存并重新连接**，即可实时同步全屋房间与设备。

---

## 📄 开源协议

本项目基于 [MIT License](LICENSE) 开源。
