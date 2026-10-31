# MenuBarMijia

macOS 菜单栏智能家居控制中心，将群晖 Home Assistant 或米家云端直连接入的设备合成为符合 Apple Control Center 交互范式的桌面面板。

## Language

### 核心领域实体

**SmartDevice（逻辑设备）**：
面板中展示与操控的最小设备单元（如一台空调、一盏吸顶灯、一台双开门冰箱），由同一物理设备下的多个 Home Assistant 原始实体或 MIoT 服务属性聚合而成。
_Avoid_: Entity（原始实体）、Widget（小组件）、Accessory（配件）

**RawEntity（原始实体）**：
底层数据源暴露的单点状态或动作寻址接口（如 Home Assistant 的 `light.*`、`sensor.*_temperature` 或米家云端的 `miot:<did>:<siid>`），仅存在于数据同步与命令下发边界，不直接暴露给用户界面。
_Avoid_: Device（设备）、Card（卡片）

**DeviceSynthesis（设备合成）**：
将 Home Assistant 注册表/状态表或米家云端设备列表/MIoT 属性值，按物理归属与功能优先级折叠为 `SmartDevice` 列表与 `EnvironmentReading` 的纯函数转换过程。
_Avoid_: Data mapping（数据映射）、Parsing（解析）

**HomeBackend（连接后端）**：
驱动 `HomeStore` 的可切换底层数据源模式，支持局域网 `Home Assistant`（`HAWebSocketProvider`）与免网关的 `米家云端直连`（`MiCloudProvider`）双后端；演示模式由 `DemoHomeProvider` 提供。这套双后端只存在于 macOS 客户端——Windows 托盘版只有米家云与演示模式，没有 HA 后端。
_Avoid_: Server type（服务器类型）、Mode（模式）

**MiSession（米家云端会话）**：
通过小米账号二维码扫码登录获取并持久化在钥匙串中的会话凭证（含 `userId`、`ssecurity`、`serviceToken` 与区域），用于签名与加解密 `/app/*` 请求。这里的 RC4 是小米云 `api.io.mi.com` 私有接口的**传输层**加密（`MIOT-ENCRYPT-ALGORITHM: ENCRYPT-RC4`），不是端到端加密：指令与状态经小米服务器中转，服务器可读明文。
_Avoid_: Token（令牌）、Cookie（网页凭据）、End-to-end encryption（端到端加密）

**MiotSpec（MIoT 设备规格）**：
由 `miot-spec.org` 定义的设备型号能力描述模型（含服务 `siid`、属性 `piid`、动作 `aiid`、取值范围与枚举列表），作为米家云端设备合成与指令映射的元数据契约并按型号缓存于本地。
_Avoid_: Schema（模式）、Profile（配置表）

**RoomArea（房间区域）**：
物理空间的归属划分（如客厅、书房、卧室、次卧、厨房），以 Home Assistant 的区域注册表或米家家庭房间列表为准并经过名称归一化。
_Avoid_: Zone（防区）、Group（分组）

**HomeOption（米家家庭）**：
小米账号下的独立家庭空间（由 `homeroom/gethome` 的 `homelist` 返回，含家庭 ID、名称与去重设备数），支持在面板顶部切换查看单个家庭或合并查看全部家庭。
_Avoid_: Workspace（工作区）、Account（账号）

**SplitDevice（多键分键设备）**：
多键 Mesh 墙壁开关等复合设备由 `v2/home/device_list_page` 拆分出的独立按键记录（`did` 形如 `<parentDid>.s2`，携带 `splitParentDid` 与 `splitSiid`）；合成时隐藏父面板并以各分键作为独立 `SmartDevice` 展示，MIoT 读写仍寻址父 `did` 与对应 `siid`。
_Avoid_: Sub-entity（子实体）、Virtual plug（虚拟插座）

**EnvironmentReading（环境读数）**：
从各房间温湿度计提取并置顶展示在面板顶部与 macOS 菜单栏的实时温湿度指标。
_Avoid_: Weather（天气）、Telemetry（遥测）

### 控制与偏好

**Scene（场景）**：
在 Home Assistant（或由米家同步至 HA）中定义的一键多设备联动动作（`scene.*` / `script.*`），在菜单栏面板中仅触发执行，不在本地维护编排逻辑。
_Avoid_: Automation（后台自动化规则）、Macro（宏）

**QuickAction（内置快捷动作）**：
基于设备类别自动聚合的批量领域指令（如「全屋关灯」「柔和夜灯」「睡眠关温控」），无需在 Home Assistant 预置场景即可一键执行。执行后按设备数给出撤销横幅：1–2 台 10 秒、3 台及以上 15 秒（`HomeStore.undoBannerSeconds(forDeviceCount:)`，指针悬停时暂停）；横幅消失后，助手的最后一次动作仍可用「撤销上一步」在 10 分钟内回滚。
_Avoid_: Local scene（本地场景）、Custom script（自定义脚本）

**AllOffTarget（全关目标）**：
「全关」实际会关闭的设备集合（`HomeStore.allOffTargets`）：当前视图内、开启中、且能从面板关闭的设备。默认不参与全关的类别（插座、扫地机、摄像机，`joinsAllOffByDefault` 返回 false）可由用户按设备覆盖（`setJoinsAllOff`），覆盖结果持久化。
_Avoid_: All devices（全部设备）

**IntentPlan（意图执行计划）**：
自然语言指令经本地规则解析（`LocalIntentParser`）或远端大模型回退（`ModelIntentResolver`）后生成的结构化设备操作列表（`[DeviceIntent]`）与简短反馈文案，经能力校验后由 `HomeStore` 并发下发并支持多设备一键撤销。
_Avoid_: Prompt output（模型输出）、Action script（动作脚本）

**ScheduledCommand（定时指令）**：
带有绝对触发时刻 `fireDate` 与已解析 `IntentPlan` 的延时控制任务，持久化在本地 `UserDefaults`（`assistant_scheduled_commands_v1`）。应用重启时未到期项按剩余时间继续倒计时；退出期间已过期项转入 `missedScheduledCommands` 待确认队列并保留在磁盘，必须由用户点击「立即执行」或「忽略」后才执行或移除，绝不在后台静默触发过期硬件动作。
_Avoid_: Background job（后台任务）、Cron（计划任务）

**ActiveDevice（活跃开启设备）**：
当前在线且处于工作状态的受控设备（开着的灯、正在制冷/制热的空调或电暖器、运行中的风扇、通电开启的插座、清扫中的扫地机、播放中的音箱、监控中的摄像机）。顶部「全关」只作用于其中参与全关的 AllOffTarget；插座、扫地机、摄像机等常年通电或看护设备默认不计入全关目标（冰箱、待机电视、纯传感器整体不算活跃设备）。
_Avoid_: Online device（在线设备）

**CompactTile（双列紧凑磁贴）**：
每行并排展示两张设备的紧凑网格视图；当任意设备展开详情抽屉时，该卡片自动切换为跨满整行宽度以容纳滑块与模式按钮。
_Avoid_: Mini card（迷你卡片）、Widget（小组件）

**SafetyAlert（主动守护提醒）**：
macOS 原生通知，覆盖四类情况：插座持续开启 45 分钟且**实时功率超过 300 W**（没有功率读数就不触发）、空调或电暖器连续运行 4 小时、传感器或门锁电量低于 15%、星标设备意外离线。低电量同一设备 24 小时内不重复提醒，冷却时间持久化（重启不重置）；带关闭动作的提醒可在通知上直接执行。
_Avoid_: Alarm（警报）、Push notification（远程推送）

**ViewPreference（本地视图偏好）**：
仅作用于当前 Mac 客户端的展示配置（包括星标常用置顶、自定义分组 `DeviceGroup`、长按拖拽排序与分页面卡片尺寸 `TileSize`、隐藏特定设备、隐藏离线设备、面板高度 `PanelHeight`、菜单栏常驻指标选择），存储在本地且不回写远端数据源。
_Avoid_: Device config（设备配置）、Profile（档案）
