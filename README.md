<p align="center">
  <img src="docs/assets/logo.svg" width="128" alt="MenuMijia">
</p>

<h1 align="center">MenuMijia</h1>

<p align="center">
  Mac 菜单栏里的米家语音助手（非官方，与小米公司无关）<br>
  <b>按住菜单栏说句话，0.2 秒全屋并发响应。不碰手机，也不跟音箱一来一回废话。</b>
</p>

> [!NOTE]
> 本项目是个人开源作品，与小米、米家、美的无关，也未获得其授权或认可。「小米」「米家」「美的」等是各自权利人的商标，本文仅用于说明兼容对象。

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/Jev-System_One_毫秒级决策-7C3AED" alt="Jev System One">
  <img src="https://img.shields.io/badge/连接方式-米家扫码直连_%7C_Home_Assistant-30D158" alt="双后端支持">
  <img src="https://img.shields.io/badge/三方Swift依赖-零-0A84FF" alt="零第三方 Swift 依赖">
</p>

<p align="center">
  <img src="docs/assets/jev-demo.gif" width="420" alt="实机演示：按住菜单栏直接说话 → Jev 毫秒级多设备并发执行 → 精准切换月光模式">
</p>

写代码写到一半，觉得屋里有点热、灯光有点刺眼。

以前你只有两个选择：
- **掏手机**：解锁 → 打开米家 → 等加载 → 找房间 → 调吸顶灯 → 退出去再找空调。六步走完，刚才代码的思路彻底断了。
- **喊小爱同学**：「小爱同学！」→ 等音箱叮一声回应「哎」→ 说「把书房灯调成月光模式」→ 等它听懂再播报一句「好的，已为您切换」→ 再喊一次「小爱同学！」去调空调。一来一回七八秒，费口舌又打断注意力。

**MenuMijia** 把这件事缩成一个动作：**鼠标按住屏幕顶部的菜单栏温度图标直接说话，松手即执行**；或者按 `⌥M` 呼出面板，敲一下键盘。

没有唤醒词，没有一来一回的语音播报，一句话同时操控多台设备，5 秒内随时一键撤销。而且现在**无需购买 NAS、无需部署 Docker 或 Home Assistant**，下载后直接掏出手机米家 App 扫个码就能用。

---

## 为什么引入 Jev 决策模型：省掉所有口舌

传统的语音助手和大语言模型（LLM）都在「生成对话文本」——哪怕只是关个灯，模型也要一个词一个词地吐出 JSON 或回复话术，不仅慢，还经常把「切换月光模式」曲解成「单纯把亮度调暗」。

本项目接入了专为结构化快速决策设计的 **Jev 模型（`~typesafe/jev-latest`，基于 `/v1/systemone` 协议）**，配合本地确定性规则引擎，构成了**双层混合决策架构**：

<p align="center">
  <img src="docs/assets/jev-vs-xiaoai.svg" width="880" alt="传统语音助手多轮对话 vs MenuMijia + Jev 毫秒级单次并发决策对比">
</p>

1. **明确指令 0 ms 本地直达（`IntentEngine`）**  
   像「打开书房灯」「书房吸顶灯月光模式」「空调 24 度」这类确定性指令，直接在本地离线匹配 Miot / HA 动作目录，**0 毫秒直发设备**，无需等待任何网络推理，且精准命中灯具原生的 `Night`（月光）/ `Day`（日光）情景模式。
2. **复杂情境 ~180 ms 全屋并发决策（`Jev /v1/systemone`）**  
   当你说出模糊情境或跨设备组合指令（例如：「**我准备写代码了，屋里稍微有点热**」），Jev 的 `/v1/systemone` 接口会在**单次 Token 前向传播**中通过 `parallel_decisions` 并发输出全屋设备的动作概率分布——同时打开书房吸顶灯、开启屏幕挂灯、把书房空调设为 24.5°C 制冷，绝不跟你多废话半句。

<p align="center">
  <img src="docs/assets/jev-decision-showcase.png" width="860" alt="实机截图：左为按住菜单栏直接说话与多设备并发执行，右为 Jev 概率分布胶囊与月光灯效抽屉">
</p>

### Jev 带来的三项个性化能力

- **🎯 模糊意图「概率追问胶囊」**：当你只说一句「稍微有点刺眼」或「有点冷」，Jev 不会自作主张乱关设备，而是直接根据单 Token 概率分布渲染出带置信度的候选胶囊（如 `✨ 书房吸顶灯切月光模式 91%`、`✨ 屏幕挂灯调至 20% 76%`），点一下立即执行。
- **✨「Jev 猜你想做」主动环境感知**：点击面板顶部的蓝色星光按钮（或栏内的 `Jev 猜你想做`），Jev 会结合**当前时段（早/中/晚/深夜）+ 各房间温湿度计实测数据 + 当前开启的设备**，推演出你此刻最可能需要的 3 个操作。
- **🧠 本地分时段习惯与口头禅记忆（`UserHabitMemory`）**：App 在本地自动学习你在清晨、下午、夜晚、深夜的高频操作组合，并记住你的个人口头禅（例如你常说的「准备写代码」「准备睡觉」对应哪几台设备的什么状态），每次请求自动注入 `<user_habits>` 上下文，越用越合手。
- **🔑 零配置自动复用 OpenRouter 密钥**：如果你本机装有 CodexBar 并配置了 OpenRouter，App 会自动识别并复用钥匙串/配置中的密钥，开箱即享 `~typesafe/jev-latest`；也支持自定义任意兼容接口。

---

## 按住菜单栏，直接开口说

不用先点开窗口、再去寻找麦克风按钮。我们在菜单栏图标上内置了双模式语音交互：

| 操作方式 | 触发逻辑 | 适合场景 |
| --- | --- | --- |
| **按住说话（Push-to-Talk）** | 鼠标左键**按住**菜单栏的 `🏠 25.4°` 图标不放（> 0.2s），面板自动弹出并开始实时听写；说完**松开鼠标**立即发送执行 | 一句话快速下达指令，像对讲机一样干脆利落 |
| **短按免提听写** | 按住菜单栏图标刚弹出（0.2s–0.45s）即松手，或按快捷键 `V` / 点面板顶部 `🎙️`，进入免提监听，**说完停顿 1.1 秒自动提交** | 手头正在忙，不想一直按着鼠标 |
| **右键一键语音** | **右键点击**菜单栏图标 | 直接弹出面板并开启语音听写 |

---

## 免装 Home Assistant：手机米家扫码，开箱即用

以前想在 Mac 菜单栏控制米家，往往得先买一台 NAS 或树莓派，折腾 Docker、部署 Home Assistant、安装插件、申请长期令牌。

现在，我们把小米云端的通信协议直接用纯 Swift 内置进了 `MijiaCore`（**零第三方依赖**），提供**双后端自由切换**：

<p align="center">
  <img src="docs/assets/dual-backend-settings.png" width="860" alt="实机截图：左为手机米家 App 扫码直连（免 NAS / 免 HA），右为 Jev 决策引擎与个人习惯记忆配置">
</p>

### 模式一：米家云端直连（推荐新用户，0 门槛）
- **手机扫码即用**：打开设置切换到「米家云端直连」，用手机「米家」App 扫一下屏幕上的二维码即可完成绑定。
- **原生 Miot-Spec 协议与 RC4 端到端加密**：内置 `MiCloudClient` 与 `MiotSynthesizer`，自动拉取你米家账号下的家庭、房间与设备列表，动态解析 `miot-spec-v2` 规格书（含吸顶灯 `mode` 日光/月光枚举、空调温控、插座功率、温湿度计、扫地机、冰箱等）。
- **隐私安全**：登录凭证（`serviceToken` / `ssecurity`）严格保存在你本机的 **macOS 系统钥匙串（Keychain）** 中，只与小米官方 `api.io.mi.com` 加密通信。

### 模式二：Home Assistant 局域网实时连接（适合已有 HA / 跨生态玩家）
- **毫秒级 WebSocket 状态同步**：通过局域网 WebSocket 订阅 `state_changed`，支持小米官方 [`xiaomi_home`](https://github.com/XiaoMi/ha_xiaomi_home) 与美的 [`midea_ac_lan`](https://github.com/wuwentao/midea_ac_lan) 集成，把米家和美的设备放进同一个面板。
- **多实体智能收拢（`DeviceSynthesizer`）**：把 HA 里拆散的开关、功率、今日电量、童锁、网关指示灯等几十条实体，自动去噪并收拢成干净的「一台物理设备一张卡」。

<p align="center">
  <img src="docs/assets/synthesizer.svg" width="860" alt="HA 里的 5 条实体，合成 1 张设备卡">
</p>

---

## 手不离开键盘

<p align="center">
  <img src="docs/assets/panel.png" width="420" alt="MenuMijia V3 主面板实机截图">
</p>

按 `⌥M` 呼出面板，再按一次收起。打开之后，全程不碰鼠标也能操控全屋：

| 按键 | 作用 |
| --- | --- |
| `⌥M` | 全局呼出 / 收起 MenuMijia 面板 |
| `V` | 直接开启 / 停止实时语音控制（说完停顿 1.1s 自动执行） |
| `/` | 呼出自然语言指令栏并聚焦输入框 |
| `1` – `9` | 直接开关列表里的第 1 – 9 台设备（按住 `⌥` 浮现数字角标） |
| `↑` `↓` | 在设备之间移动焦点 |
| `Space` / `Return` | 开关当前设备；不能直接开关的，展开详情抽屉 |
| `→` `←` | 展开详情，再步进调节亮度 ±10%、温度 ±1°C、音量 ±10% |
| `Tab` | 在「全部」和各个房间之间切换 |
| `Esc` | 收起语音/指令栏、收起详情抽屉，或关闭面板 |

---

## 每类设备，都有趁手的专属控件

点开卡片右侧箭头，展开该品类专属的 Liquid Glass 控制抽屉：

| 设备 | 抽屉里能做什么 |
| --- | --- |
| **灯光** | 亮度 1–100% 液态滑块、色温 2700–6500K 光谱滑块、**日光 / 月光 (`Night`) / 阅读 / 电脑** 等原生情景模式一键切换 |
| **空调 · 电暖器** | 目标温度 0.5°C 步进、对照当前室温、制冷 / 制热 / 除湿 / 送风模式、风速档位与摆风开关 |
| **风扇** | 开关、风速百分比、自然风 / 直吹风预设模式、摇头控制 |
| **插座** | 实时功率（W）、今日用电量（kWh）、物理按键童锁开关 |
| **冰箱** | 冷藏室与冷冻室实测温度、目标温度调节，智能 / 速冷 / 速冻 / 假日模式切换 |
| **扫地机** | 清扫状态与电量显示，开始清扫 / 暂停 / 立即回充 |
| **小爱音箱** | 音量滑块、静音、放歌、停闹钟；直接打字让小爱 TTS 播报或静默执行指令 |
| **电视** | 唤醒开机、音量调节、输入信源切换 |

### 睡前一键全关 + 5 秒防误触撤销

面板右上角的「**全关**」会一键关掉所有正在运行的灯、空调、电暖器、风扇和插座；下方快捷栏提供「**全屋关灯**」「**柔和夜灯**」「**关温控风扇**」。

无论是手动点错，还是语音 / Jev 并发执行了多台设备，面板底部都会浮起一条 **5 秒撤销横幅**——点一下「**撤销**」，所有被改动的设备立即恢复到执行前的精确状态（含原亮度、色温、灯效与空调温度）。

---

## 菜单栏常驻与主动安全守护

<p align="center">
  <img src="docs/assets/menubar.png" width="330" alt="菜单栏图标">
</p>

- **菜单栏一眼掌握室温与功耗**：支持在菜单栏常驻显示任意房间的温度、温湿度同显、全屋插座实时总功率、开启中的设备数，或仅保留简洁小房子图标。
- **主动安全与低电量提醒**：
  - 咖啡机这类大功率插座连续开启超过 45 分钟，或空调、电暖器连续运行超过 4 小时，弹出 macOS 原生通知，支持在通知上直接点「**立即关闭**」
  - 温湿度计、门锁电量低于 15% 自动提醒（24 小时内不重复打扰）
  - 星标的常用设备突然掉线断电提醒

---

## 常用说法

打开指令栏（`⌥M` 或按住菜单栏图标）直接说。下面这些不用联网，本地 0ms 就能听懂：

| 想做的事 | 可以这样说 |
| --- | --- |
| 开关 | 「关客厅灯」「把空调打开」 |
| 微调亮度 | 「再暗一点」「主卧灯亮一点」 |
| 微调温度 | 「调高两度」「温度低一点」 |
| 风扇 | 「风扇开高档」「风速调低」「摇头」「停止摇头」 |
| 定时 | 「10 分钟后关灯」「半小时后关空调」；「取消定时」 |
| 撤销 | 「撤销」「刚才那个撤销」（10 分钟内有效） |

> [!NOTE]
> 没说具体设备的微调（比如「再暗一点」）只作用于**正开着**的设备。定时只在 App 运行期间有效，退出或重启后不会保留。

---

## 隐私

- **默认留在本机**：习惯记忆、口头禅、设备列表都存在你的 Mac 上；米家登录信息和 API 密钥存在钥匙串里。
- **发给 AI 的内容**：只有本地听不懂的话才会发给你配置的模型接口，内容是这句话、设备名称/房间/状态、时间段、室温，以及（如果开着）习惯摘要。API Key 和米家登录信息不会发送。设置页里写得很清楚。
- **可以关**：设置里能关掉「学习我的使用习惯」（关掉后不再记录，也不会发给 AI），也能逐条删除已记住的习惯。
- **语音可以只在本机识别**：打开「语音只在本机识别」后，声音不会发给苹果（需要系统支持该语言的离线识别）。

---

## 快速开始

**运行环境**：macOS 26 及以上，Xcode 26 / Swift 6。

### 1. 编译并启动应用

```bash
git clone https://github.com/jryang1997/MenuBarMijia.git
cd MenuBarMijia
bash scripts/build_app.sh       # 编译 Release，签名打包并启动「MenuMijia.app」
```

> [!TIP]
> `scripts/build_app.sh` 会自动生成包含麦克风与语音识别权限声明的 `MenuMijia.app` 并完成本地签名。你可以直接将生成的 `MenuMijia.app` 拖入 `/Applications`（应用程序）文件夹，并在设置中开启「登录 Mac 时自动启动」。

### 2. 连接你的米家设备（二选一）

#### 方式 A：米家云端扫码直连（推荐，无需任何额外硬件）
1. 点击菜单栏里的小房子图标 → 点击右下角设置按钮 `⚙️`
2. 在「连接配置」中选择 **「米家云端直连」**
3. 点击 **「扫码登录米家账号」**，用手机「米家」App 扫描二维码确认
4. 登录成功后，家庭房间与全屋设备会自动同步进面板，立即可控！

#### 方式 B：macOS 连接局域网 Home Assistant（可选）
1. 在「连接配置」中选择 **「Home Assistant」**，填入 HA 地址（如 `http://192.168.1.100:8123`）和长期访问令牌
2. 如果你有群晖 NAS 但还没装 HA，可使用仓库自带的一键部署脚本：`bash nas/deploy_ha.sh`（自动拉取镜像并预装 `xiaomi_home` 与 `midea_ac_lan`）

首次连接需要填写你自己的 HA 地址和长期访问令牌。令牌在 HA 的用户个人资料页面创建。连接后，客户端自动读取设备、实体、区域与状态，将已支持的设备类型合成到面板，无需逐台添加。默认地址为 `http://homeassistant.local:8123`；如果无法解析该主机名，填写 HA 的局域网 IP 地址。

---

## 参与开发与架构说明

纯 Swift Package，**零第三方 Swift 依赖**，开启 Swift 6 严格并发检查（Strict Concurrency）。核心协议、Miot-Spec 合成器、Jev `/v1/systemone` 决策客户端与习惯记忆引擎均位于独立的 `MijiaCore` 库中，可脱离 UI 单独运行单元测试。

```bash
bash scripts/check.sh           # 隐私/密钥扫描 + 编码规范检查 + swift test
bash scripts/linux-check/run.sh # 没有 Mac 时：在 Linux 上编译并测试 MijiaCore（需要 Swift 6.1）
```

### Windows 11 系统托盘版（`windows/`）

仓库内置基于 **Tauri v2 (Rust + TypeScript + WebView2)** 的 Windows 11 系统托盘客户端，完整复刻小米云 RC4 加密协议、二维码扫码直连、Miot-Spec 自动合成、0ms 本地解析、OpenRouter Jev `/v1/systemone` 决策引擎、定时倒计时与 10 分钟内撤销，并支持 `Alt+M` 全局热键呼出。

Windows 版目前支持米家云扫码直连和演示模式，Home Assistant 连接仅在 macOS 版实现。Windows 的设备控制在云端确认成功后更新卡片，失败时显示错误；批量操作会报告部分失败，撤销只恢复成功指令修改过的属性，并保留原始开关状态。撤销失败可以重试；缺少原始属性值或操作无法逆转时，不提供撤销按钮。

```bash
cd windows
npm install
npm test        # 运行协议、意图解析和页面控制/撤销回归测试
npm run build   # TypeScript 严格类型检查 + 前端打包
npx tauri build # 在 Windows 上打包 .exe (NSIS) 与 .msi 安装包
```

每次推送到 `main` 分支时，GitHub Actions（`windows-latest`）会自动编译并把 `MenuMijia-1.0.0-windows-x64-setup.exe` 与 `.msi` 附加到 [GitHub Releases](https://github.com/jryang1997/MenuBarMijia/releases)。

### 发布 macOS 安装版

```bash
DEVELOPER_ID="Developer ID Application: 你的名字 (TEAMID)" \
bash scripts/release.sh         # 签名 → 打 DMG → 苹果公证 → 盖章，产物在 dist/
```

版本号写在 `VERSION` 文件里，构建号自动取 git 提交数。需要苹果开发者账号；公证凭据先用 `xcrun notarytool store-credentials menumijia-notary` 存好（脚本开头有完整步骤）。只想本地打包、不公证：加 `SKIP_NOTARIZE=1`。把 DMG 上传到 GitHub Releases 后，用户在设置页点「检查更新」就能看到。

提交前请先阅读 [`CODING_STANDARDS.md`](CODING_STANDARDS.md)。领域术语见 [`GLOSSARY.md`](GLOSSARY.md)，架构决策记录在 [`docs/adr/`](docs/adr/)。

<details>
<summary>目录结构</summary>

```text
Sources/
├── MijiaCore/                          领域、协议与智能决策层（零 UI 依赖）
│   ├── Models.swift                    统一设备领域模型：SmartDevice / DeviceKind / DeviceCommand
│   ├── CommandIntent.swift             意图模型（开关、亮度、色温、相对微调、风扇档位、摇头……）与校验
│   ├── LocalIntentParser.swift         0ms 本地自然语言解析
│   ├── ModelIntentResolver.swift       Jev /v1/systemone 概率决策客户端与错误提示
│   ├── AssistantConfig.swift           模型接口配置
│   ├── AssistantSchedule.swift         「10 分钟后…」「取消定时」「撤销」的说法识别
│   ├── UserHabitMemory.swift           本地分时段习惯学习与个人口头禅记忆引擎
│   ├── UpdateChecker.swift             读取 GitHub Releases 检查新版本
│   ├── MiCloud/                        小米云直连后端（免 Home Assistant）
│   │   ├── MiAccountLogin.swift        小米账号二维码生成、长轮询登录与 Keychain 会话管理
│   │   ├── MiCloudClient.swift         小米 IoT 云端 RC4 加密签名与 Miot-Spec RPC 客户端
│   │   ├── MiotSpecCache.swift         miot-spec-v2 规格书拉取与本地磁盘缓存
│   │   ├── MiotSynthesizer.swift       Miot 属性到 SmartDevice 的自动合成与日光/月光灯效映射
│   │   └── MiCloudProvider.swift       小米云实时轮询与指令派发 Provider
│   ├── DeviceSynthesizer.swift         Home Assistant 多实体聚合、房间排序、噪音过滤
│   ├── HomeProvider.swift              HomeProvider 协议、HA WebSocket 实时流与 MockProvider
│   ├── HomeStore.swift                 @Observable 状态中心：双后端切换、乐观锁、防抖、5s 撤销
│   ├── HomeStore+Assistant.swift       指令执行：意图落地、定时、语音撤销
│   └── KeychainAndPrefs.swift          macOS 钥匙串安全存储与偏好设置
└── MenuBarMijiaApp/                    SwiftUI + AppKit 原生界面层
    ├── MenuBarMijiaApp.swift           应用入口与生命周期绑定
    ├── ControlCenterPanel.swift        主面板、环境胶囊、快捷场景栏、浮动撤销横幅
    ├── AssistantCommandBar.swift       自然语言指令栏、SFSpeech 实时语音听写、Jev 概率胶囊
    ├── MiAccountSection.swift          米家扫码登录与云端状态组件
    ├── DeviceCardView.swift            双列 Liquid Glass 磁贴与 8 大品类专属控制抽屉
    ├── HotkeyAndNotificationManager.swift  NSStatusItem 菜单栏长按说话、⌥M 热键与主动安全通知
    ├── SettingsSheetView.swift         双后端连接配置、Jev 决策设置与偏好面板
    └── ThemeAndMotion.swift            macOS 26 Liquid Glass 材质与阻尼弹簧动效
Tests/MijiaCoreTests/                   Swift Testing 单元测试套件（覆盖合成、Miot、Jev、习惯记忆等）
scripts/                                打包（build_app.sh）、发布公证（release.sh）、门禁检查（check.sh）、Linux 测试（linux-check/）
nas/                                    群晖 NAS 一键部署 Home Assistant 脚本（可选）
docs/                                   ADR、规格文档与 README 实机截图/动图资源
```

</details>

## 第三方组件说明

本仓库不包含、也不分发以下第三方集成，NAS 部署脚本仅在你需要 Home Assistant 模式时从官方地址下载到你自己的设备上：

| 组件 | 来源 | 许可 |
| --- | --- | --- |
| Xiaomi Home Integration（`xiaomi_home`） | [XiaoMi/ha_xiaomi_home](https://github.com/XiaoMi/ha_xiaomi_home) | 小米自有许可，见 [LICENSE.md](https://github.com/XiaoMi/ha_xiaomi_home/blob/main/LICENSE.md) |
| Midea AC LAN（`midea_ac_lan`） | [wuwentao/midea_ac_lan](https://github.com/wuwentao/midea_ac_lan) | MIT，见 [LICENSE](https://github.com/wuwentao/midea_ac_lan/blob/master/LICENSE) |
| Home Assistant | [home-assistant/core](https://github.com/home-assistant/core) | Apache-2.0 |

本仓库的 MIT 许可覆盖本项目自身的全部源码。

## License

[MIT](LICENSE) © Zhiyuan Yang
