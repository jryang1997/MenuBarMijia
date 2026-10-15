# MenuBarMijia V2 规格说明（场景栏、全局键盘流、双列磁贴与主动守护）

## 1. 模块 A：一键场景栏与内置快捷动作（Scenes & QuickActions）
- **HA 场景同步（`HomeScene`）**：`DeviceSynthesizer.synthesize` 自动提取 Home Assistant 中未禁用、未隐藏且可用的 `scene.*` 与 `script.*` 实体，生成 `[HomeScene]`；`DeviceCommand.activateScene(entityId:)` 通过 `/api/services/scene/turn_on` 或 `/api/services/script/turn_on` 触发。
- **内置快捷动作（`QuickAction`）**：提供开箱即用的三项领域级批量指令，可在设置中开关显示：
  1. `lightsOff`（「全屋关灯」）：关闭所有在线且开启中的灯光设备。
  2. `softNightLight`（「柔和夜灯」）：将所有在线且开启中的灯光设为 `15%` 亮度与 `2700K` 暖光（若无开启中的灯，则开启常用/主卧灯至 `15%` 暖光）。
  3. `climateSleepOff`（「关温控与风扇」）：关闭所有在线且开启中的空调、电暖器与风扇。
- **快照撤销**：所有 `QuickAction` 均生成 5 秒 `UndoBanner`，支持一键恢复执行前的设备状态与指令。

## 2. 模块 B：全局快捷键与纯键盘操控（Global Hotkey & Keyboard Navigation）
- **全局唤起热键**：默认支持 `⌥M`（Option + M，可在设置中开关）呼出或收起菜单栏控制中心弹窗。
- **键盘导航状态机（`HomeStore`）**：
  - 数字键 `1`~`9`（`selectQuickIndex`）：直接切换当前可见列表第 `1`~`9` 台设备的主开关。
  - `↑` / `↓`（`moveFocus`）：在当前可见设备列表间移动键盘高亮焦点（`focusedDeviceId`）。
  - `Space` / `Return`（`toggleFocusedDevice`）：切换当前焦点设备的主开关（不可直接开关的设备则展开/收起详情抽屉）。
  - `→` / `←`（`adjustFocusedDevice`）：当焦点设备未展开时，按 `→` 展开详情抽屉；当已展开时，按 `←` / `→` 步进调节亮度（`±10%`）、目标温度（`±1°C`）或音量（`±10%`），再次按 `Esc` 收起抽屉或关闭面板。
  - `Tab`（`cycleRoom`）：在「全部」与各房间筛选标签之间循环切换。
- **数字角标按需浮现**：卡片上的 `1`~`9` 快捷键角标平时隐藏，仅在按住 `⌥`（Option）键或存在键盘焦点时展示。

## 3. 模块 C：设备自定义排序、单设备隐藏与双列紧凑磁贴（ViewPreference & CompactTile）
- **星标常用排序（`favoriteOrder`）**：支持对「常用控制」中的星标设备上移/下移调整顺序（`moveFavorite`），持久化至本地 `UserDefaults`。
- **单设备隐藏（`hiddenDeviceIds`）**：支持通过设备卡片右键菜单「隐藏此设备」（`hideDevice`），从主面板过滤；在设置页展示「已隐藏设备」列表并支持一键恢复（`unhideDevice`）。
- **单列 / 双列紧凑磁贴切换（`isCompactGridMode`）**：
  - 面板支持一键切换「单列详情」与「双列紧凑磁贴（`CompactTile`）」。
  - 在双列模式下，未展开的设备以每行 2 张紧凑磁贴并排显示：点击左侧圆形图标直接切换开关，点击右侧标题区域将该卡片跨满整行（full-width span）展开控制抽屉。

## 4. 模块 D：动态菜单栏指标与主动守护通知（Dynamic Menu Bar & SafetyAlert）
- **动态菜单栏指标（`menuBarTargetId`）**：
  - 支持在设置中选择任意在线温湿度计显示「仅温度（如 `26.6°`）」或「温湿度同显（如 `26.6° 57%`）」。
  - 新增「全屋实时总功率（如 `1150W`）」选项（汇总所有在线开启插座的 `powerWatts`），以及原有的「开启设备数」「仅显示图标」。
- **主动守护引擎（`SafetyAlert`）**：
  - **低电量守护**：当温湿度计或门锁电量 `< 15%` 时触发提醒，同一设备 24 小时内最多提醒 1 次。
  - **高功率与温控长开守护**：插座（如咖啡机）连续开启满 45 分钟、或空调/电暖器连续开启满 4 小时触发提醒（附带可立即关闭该设备的 `turnOffCommand`），同一开启周期内仅提醒 1 次。
  - **星标设备离线守护**：仅当星标（常用控制）设备从在线变为离线时触发提醒。
  - 可在设置页独立开关主动守护提醒，并通过 macOS `UNUserNotificationCenter` 投递系统通知（附带「立即关闭」动作按钮）。
