# MenuBarMijia (米家控制中心)

macOS 菜单栏智能家居控制中心，将群晖 Home Assistant 接入的米家设备合成为符合 Apple Control Center 交互范式的桌面面板。

## Language

### 核心领域实体

**SmartDevice（逻辑设备）**：
面板中展示与操控的最小设备单元（如一台空调、一盏吸顶灯、一台双开门冰箱），由同一物理设备下的多个 Home Assistant 原始实体聚合而成。
_Avoid_: Entity（原始实体）、Widget（小组件）、Accessory（配件）

**RawEntity（原始实体）**：
Home Assistant 暴露的底层单点状态或动作接口（如 `light.*`、`sensor.*_temperature`、`select.*_mode`、`notify.*`），仅存在于数据同步与命令下发边界，不直接暴露给用户界面。
_Avoid_: Device（设备）、Card（卡片）

**DeviceSynthesis（设备合成）**：
将 Home Assistant 的区域、设备注册表、实体注册表与实时状态表，按物理归属与功能优先级折叠为 `SmartDevice` 列表与 `EnvironmentReading` 的纯函数转换过程。
_Avoid_: Data mapping（数据映射）、Parsing（解析）

**RoomArea（房间区域）**：
物理空间的归属划分（如客厅、书房、卧室、次卧、厨房），以 Home Assistant 的区域注册表为准并经过名称归一化。
_Avoid_: Zone（防区）、Group（分组）

**EnvironmentReading（环境读数）**：
从各房间温湿度计提取并置顶展示在面板顶部与 macOS 菜单栏的实时温湿度指标。
_Avoid_: Weather（天气）、Telemetry（遥测）

### 控制与偏好

**Scene（场景）**：
在 Home Assistant（或由米家同步至 HA）中定义的一键多设备联动动作（`scene.*` / `script.*`），在菜单栏面板中仅触发执行，不在本地维护编排逻辑。
_Avoid_: Automation（后台自动化规则）、Macro（宏）

**QuickAction（内置快捷动作）**：
基于设备类别自动聚合的批量领域指令（如「全屋关灯」「柔和夜灯」「睡眠关温控」），无需在 Home Assistant 预置场景即可一键执行，并支持 5 秒快照撤销。
_Avoid_: Local scene（本地场景）、Custom script（自定义脚本）

**ActiveDevice（活跃开启设备）**：
当前在线且处于工作状态的受控设备（开着的灯、正在制冷/制热的空调或电暖器、运行中的风扇、通电开启的插座、清扫中的扫地机、播放中的音箱），计入顶部「全关」统计；常年通电的基础设施设备（如冰箱、待机电视、纯传感器）不计入。
_Avoid_: Online device（在线设备）

**CompactTile（双列紧凑磁贴）**：
每行并排展示两张设备的紧凑网格视图；当任意设备展开详情抽屉时，该卡片自动切换为跨满整行宽度以容纳滑块与模式按钮。
_Avoid_: Mini card（迷你卡片）、Widget（小组件）

**SafetyAlert（主动守护提醒）**：
针对传感器低电量（`<15%`）、高功率电器超时开启（咖啡机、电暖器、空调）及星标设备意外离线发出的 macOS 原生通知，具备冷却去重与通知栏一键关闭动作。
_Avoid_: Alarm（警报）、Push notification（远程推送）

**ViewPreference（本地视图偏好）**：
仅作用于当前 Mac 客户端的展示配置（包括星标常用置顶、自定义排序、隐藏特定设备、隐藏离线设备、单/双列视图模式、菜单栏常驻指标选择），存储在本地且不回写 Home Assistant。
_Avoid_: Device config（设备配置）、Profile（档案）
