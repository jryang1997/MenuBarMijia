<p align="center">
  <img src="docs/assets/logo.svg" width="128" alt="米家控制中心">
</p>

<h1 align="center">米家控制中心</h1>

<p align="center">
  住在 macOS 菜单栏里的米家遥控器。<br>
  <b>不碰手机，不断心流。</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/依赖-零-30D158" alt="零依赖">
  <img src="https://img.shields.io/badge/License-MIT-0A84FF" alt="MIT">
</p>

<p align="center">
  <img src="docs/assets/panel.png" width="420" alt="米家控制中心面板截图">
</p>

写代码写到一半，想关个灯。

摸出手机、解锁、打开米家、等它加载、找到书房、点开吸顶灯。六步走完，刚才在想什么已经忘了。

米家控制中心把这件事缩成一步：**点一下菜单栏，或者按 `⌥M`**。全屋设备都在这里，开关、调光、一键全关，手不用离开键盘。

它是一个原生 SwiftUI 应用，通过局域网里的 [Home Assistant](https://www.home-assistant.io) 连接小米官方 [`xiaomi_home`](https://github.com/Xiaomi/ha_xiaomi_home) 和美的 [`midea_ac_lan`](https://github.com/wuwentao/midea_ac_lan) 集成。米家和美的设备，放在同一个面板里。

## 手不离开键盘

按 `⌥M` 呼出面板，再按一次收起。打开之后，不碰鼠标也能把事做完：

| 按键 | 作用 |
| --- | --- |
| `1` – `9` | 直接开关列表里的第 1 – 9 台设备 |
| `↑` `↓` | 在设备之间移动焦点 |
| `Space` / `Return` | 开关当前设备；不能直接开关的，展开详情 |
| `→` `←` | 展开详情，再步进调节亮度 ±10%、温度 ±1°C、音量 ±10% |
| `Tab` | 在「全部」和各个房间之间切换 |
| `Esc` | 收起详情，或关闭面板 |

卡片上的数字角标平时是隐藏的，按住 `⌥` 时才浮现，界面保持干净。

## 一台设备，就是一张卡

在 Home Assistant 里，一个智能插座会拆成开关、指示灯、童锁、功率、电量 5 条实体，一个小爱音箱能拆出十几条。大多数菜单栏工具会把它们原样平铺出来，用起来像在翻数据库。

`DeviceSynthesizer` 会读取 HA 的区域、设备和实体注册表，把属于同一台物理设备的实体收拢成一张卡，再按房间排好。网关指示灯、重复的 DLNA / Apple TV 映射这类噪音，会被直接过滤掉。

<p align="center">
  <img src="docs/assets/synthesizer.svg" width="860" alt="HA 里的 5 条实体，合成 1 张设备卡">
</p>

## 睡前，一键搞定

面板右上角的「全关」，会关掉所有正在运行的灯、空调、电暖器、风扇和插座。下面一排是常用场景：

- **全屋关灯**：只关灯，其他设备不动
- **柔和夜灯**：把开着的灯调到 15% 亮度、2700K 暖光
- **关温控风扇**：关掉空调、电暖器和风扇

你在 Home Assistant 里建好的场景和脚本，也会自动出现在这一排。

按错了也没关系。底部会浮起一条撤销提示，5 秒内点「撤销」，每台设备回到原来的状态。

## 点下去，立刻就变

面板通过 WebSocket 长连接订阅 `state_changed`。家里有人用手机或墙壁开关改了状态，菜单栏这边同步更新，不用手动刷新。

- **先响应，再确认**：点击后界面立即变化，HA 确认失败会自动回滚
- **滑块防抖**：拖动亮度、色温时不连发，停手 280 ms 后才发出指令
- **连接常在**：25 秒心跳保活；断线后从 0.8 秒开始、最长 10 秒的退避重连

## 每类设备，都有自己的控件

点开卡片右侧的箭头，展开这类设备专属的控制抽屉：

| 设备 | 抽屉里能做什么 |
| --- | --- |
| 灯光 | 亮度 1–100%、色温 2700–6500K、日光 / 月光情景 |
| 空调 · 电暖器 | 目标温度步进、对照当前室温、制冷 / 制热 / 除湿 / 送风 |
| 风扇 | 开关、预设风速模式 |
| 插座 | 实时功率、今日用电、按键锁 |
| 冰箱 | 冷藏室与冷冻室的实测温度、目标温度，切换冰箱支持的模式 |
| 扫地机 | 清扫状态与电量，开始 / 暂停 / 回充 |
| 小爱音箱 | 音量、静音、放歌、停闹钟；直接打字，让小爱播报或执行指令 |
| 电视 | 唤醒开机、音量 |

## 替你留意着

有些事不该靠记性。打开「主动提醒」后，它会用 macOS 系统通知告诉你：

- 咖啡机这类插座连续开了 45 分钟，或空调、电暖器连续开了 4 小时，通知里可以直接「立即关闭」
- 温湿度计、门锁电量低于 15%
- 星标的常用设备突然离线

每种提醒都有节制：同一台设备低电量 24 小时内只提醒一次，长开提醒每个开启周期只提醒一次。

## 菜单栏，一眼就够

<p align="center">
  <img src="docs/assets/menubar.png" width="330" alt="菜单栏图标">
</p>

菜单栏图标旁可以常驻显示任意一个温湿度计的温度（也可以温湿度同显）、全屋插座的实时总功率、开启中的设备数，或者只留一个小房子。

还有一些顺手的细节：

- **双列磁贴**：一键切换单列详情和双列紧凑磁贴；点图标直接开关，点标题展开控制
- **常用置顶**：星标设备放进「常用控制」，可以自己调整顺序
- **隐藏设备**：右键「隐藏此设备」，不想看到的从面板里拿掉，设置里随时恢复
- **登录自启**：可设置登录 Mac 时自动启动
- **令牌安全**：访问令牌存放在 macOS 钥匙串里，App 只与你局域网内的 Home Assistant 通信

## 开始使用

**环境**：macOS 26 及以上，Xcode 26 / Swift 6。

### 1. 准备 Home Assistant

已经有 Home Assistant，并装好了 `xiaomi_home` 集成？在 HA 网页端点击左下角头像 → **安全** → 创建一个**长期访问令牌**，备用。

还没有？如果你有装了 Container Manager 的群晖 NAS，仓库里带了一键部署脚本：

```bash
bash nas/deploy_ha.sh
```

按提示填入 NAS 的局域网 IP 和管理员账号。脚本会拉取镜像、以 host 网络模式启动 Home Assistant，并预装 `xiaomi_home` 与 `midea_ac_lan`。

### 2. 编译应用

```bash
bash scripts/build_app.sh       # 编译 Release，打包成「米家控制中心.app」
open "米家控制中心.app"           # 也可以先拖进「应用程序」文件夹
```

### 3. 连接

1. 点击菜单栏里的小房子图标，打开面板
2. 点右下角的设置按钮（首次启动时点「前往连接配置」）
3. 填入 HA 地址（如 `http://192.168.1.100:8123`）和长期访问令牌
4. 点「保存并重新连接」，房间和设备会自动同步进来

## 参与开发

纯 Swift Package，没有任何第三方依赖，开启 Swift 6 严格并发检查。核心逻辑放在独立的 `MijiaCore` 库里，可以脱离界面单独测试。

```bash
bash scripts/check.sh           # 密钥扫描 + 编码规范检查 + swift test
```

提交前请先读 [`CODING_STANDARDS.md`](CODING_STANDARDS.md)。领域术语见 [`GLOSSARY.md`](GLOSSARY.md)，架构决策记录在 [`docs/adr/`](docs/adr/)，V2 的完整规格在 [`docs/specs/`](docs/specs/)。

<details>
<summary>目录结构</summary>

```text
Sources/
├── MijiaCore/                          领域与通信层
│   ├── Models.swift                    设备模型：SmartDevice / DeviceKind / DeviceCommand
│   ├── DeviceSynthesizer.swift         多实体聚合、场景提取、房间排序、噪音过滤
│   ├── HomeProvider.swift              HA WebSocket 实时流 + REST 调用，附 MockProvider
│   ├── HomeStore.swift                 @Observable 状态中心：乐观更新、防抖、撤销、键盘导航
│   └── KeychainAndPrefs.swift          钥匙串令牌与偏好设置
└── MenuBarMijiaApp/                    SwiftUI + AppKit 界面层
    ├── MenuBarMijiaApp.swift           MenuBarExtra 入口
    ├── ControlCenterPanel.swift        主面板、场景栏、房间筛选、浮动提示
    ├── DeviceCardView.swift            设备卡片、双列磁贴与各品类控制抽屉
    ├── HotkeyAndNotificationManager.swift  全局快捷键与系统通知
    ├── SettingsSheetView.swift         偏好设置与 HA 连接配置
    └── ThemeAndMotion.swift            Liquid Glass 材质与弹簧动效
Tests/MijiaCoreTests/                   Swift Testing 单元测试
scripts/                                打包（build_app.sh）与提交前检查（check.sh）
nas/                                    群晖一键部署 Home Assistant 及集成
docs/                                   ADR、V2 规格与 README 配图
```

</details>

## License

[MIT](LICENSE) © Zhiyuan Yang
