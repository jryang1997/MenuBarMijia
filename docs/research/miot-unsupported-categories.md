# 议题 #98 延伸调研：MenuBarMijia 还没支持的米家设备品类与可行性

调研日期：2026-10-31　数据源：`https://miot-spec.org/miot-spec-v2/instances?status=released`（当日 16,148 条实例 / 171 个设备类型）+ 逐型号 `instance?type=<urn>` 规格
方法：把 `MiotSynthesizer.primary(for:)` 的选择逻辑在脚本里对真实规格逐条重放，得到「当前 App 对每个品类的真实行为」，再对头部品类抽样读取完整 MIoT 规格。

## 0. 结论先行

1. **「都不支持」是错觉。** 真正被静默丢弃的头部品类只有十余个：`curtain`（965 实例）、`water-heater`（178）、`hood`（146）、`fridge`（372）、`humidifier`（121）、`airer`（261）、`washer`（326）、`bath-heater`（281）等——它们几乎全部可以只用标准 `miotspec/prop/get` + `prop/set` + `action` 完整支持，**没有任何 P2P/BLE 私有通道障碍**。
2. **今天已顺手修掉一个真 bug**：`hood`/`airer`/`bath-heater`/`ceiling-fan`/`gateway` 这类自带 `light` 副服务的设备，会被合成器回退逻辑错认成「裸灯卡片」——面板上显示一盏只能开关那盏灯的灯，主功能（烟机排风、晾衣架升降、浴霸风暖）完全不可见。修复后：非照明类设备类型在回退时跳过 `light` 服务，宁可诚实丢弃（进入「未显示设备」诊断列表）也不冒充灯/插座。
3. **`video-doorbell` 品类零成本接入**：其规格服务（`on`、`night-shot`、`motion-detection`）与 `camera-control` 形状一致，直接复用 `buildCamera` 即可给门铃提供开关/夜视/移动侦测控制（视频仍是 P2P，同 #97 边界）。
4. **做不到的事也说清楚**：门锁**不能**通过 MIoT 远程开锁（所有 `lock` 属性 `access: []`、零动作，这是小米安全设计）；无状态无线遥控器（`remote-control`）没有可读状态做不了卡片；部分新型 Aqara 人体传感器只发 MIoT 事件（`lumi.motion.acn001` 无 `motion-state` 属性），轮询模型拿不到「有人/无人」，只能报光照。
5. 空气净化器（`zhimi.airp.rma3` 等 85 个型号）已在本次 [#98](https://github.com/jryang1997/MenuBarMijia/issues/98) 支持：PM2.5/空气质量/温湿度/滤芯显示 + 最爱挡位风速滑块。

## 1. 未支持品类排行（released 实例数，Mi 生态 = model 前缀属于小米生态）

| # | 品类 (urn 第 3 段) | 实例 | Mi 生态 | 当前行为 | 可否纯 MIoT 支持 |
|---|---|---|---|---|---|
| 1 | `curtain` 窗帘 | 965 | 169 | 丢弃 | ✅ 完整 |
| 2 | `camera` 摄像头 | 284 | 150 | ✅ 已支持（视频走 P2P） | ⚠️ 控制可以，视频见 #97 |
| 3 | `water-heater` 热水器 | 178 | 119 | 丢弃 | ✅ 完整 |
| 4 | `hood` 油烟机 | 146 | 91 | **误显示为灯**（已修） | ✅ 完整 |
| 5 | `lock` 门锁 | 299 | 87 | 丢弃 | ❌ 规格只读 |
| 6 | `fridge` 冰箱 | 372 | 86 | 丢弃（`FridgeSpec` 已存在） | ✅ 完整 |
| 7 | `router` 路由器 | 89 | 84 | 丢弃 | ⚠️ 仅状态 |
| 8 | `humidifier` 加湿器 | 121 | 70 | 丢弃 | ✅ 完整 |
| 9 | `speaker` 小爱音箱 | 93 | 59 | 丢弃（`SpeakerSpec` 已存在） | ✅ 完整 |
| 10 | `airer` 晾衣架 | 261 | 55 | **误显示为灯**（已修） | ✅ 完整 |
| 11 | `washer` 洗衣机 | 326 | 45 | 丢弃 | ✅ 完整 |
| 12 | `bath-heater` 浴霸 | 281 | 44 | **误显示为灯**（已修） | ✅ 完整 |
| 13 | `water-purifier` 净水器 | 219 | 40 | 丢弃 | ⚠️ 无开关，滤芯/水质向 |
| 14 | `television` 电视 | 97 | 39 | 丢弃（`TVSpec` 已存在） | ⚠️ 关机是普通 action，**开机走 BLE** |
| 15 | `dishwasher` 洗碗机 | 173 | 38 | 丢弃 | ✅ 完整 |
| 16 | `video-doorbell` 可视门铃 | 40 | 4 | 丢弃（已修：复用 camera） | ✅ 控制 |
| 17 | `oven` 蒸烤箱 | 88 | 16 | 丢弃 | ✅ 基础 |
| 18 | `toilet` 智能马桶 | 66 | 15 | 丢弃 | ✅ 完整 |
| 19 | `pet-feeder` 喂食器 | 31 | 13 | 丢弃 | ⚠️ 出粮 ✅，排程是私有串 |
| 20 | `air-fresh` 净味器 | 102 | 12 | 丢弃 | ✅ 完整 |
| 21 | `dehumidifier` 除湿机 | 80 | 10 | 丢弃 | ✅ 完整 |
| 22 | `electric-blanket` 电热毯 | 93 | 9 | 丢弃 | ✅ 完整 |
| 23 | 各类传感器 | ~150 | ~30 | 丢弃 | ✅ 只读（人体部分型号仅事件） |

## 2. 分层可行性

| 层级 | 品类 | 依据 |
|---|---|---|
| **A. 标准 MIoT 全量可控**（`prop/get`+`prop/set`+`action`，无私有通道） | curtain, humidifier, dehumidifier, water-heater, airer, hood, fridge, washer, dishwasher, oven, toilet, air-fresh, electric-blanket, bath-heater, ceiling-fan, pet-feeder(出粮), television(控制), video-doorbell(控制) | 每个动作都是类型化属性或零参/简单参 action |
| **B. 只读或部分** | lock（零可写属性）、magnet/submersion/illumination/occupancy-sensor（天然只读）、motion-sensor（部分仅事件）、gateway（仅布防）、router、water-purifier、window-opener（无位置反馈）、remote-control（无状态） | 规格没有可写面 |
| **C. 需要非 MIoT 通道** | 摄像头/门铃**视频**、PTZ、双向语音；音箱 TTS 之外的高级玩法 | `p2p-stream` 动作无入参无出参，媒体面在 HTTP 之外（见 [issue-97-camera-support.md](issue-97-camera-support.md)） |

## 3. 代表性规格摘录（实现新 builder 时按名解析，勿硬编码枚举值）

### curtain（965 实例，`lumi.curtain.hagl05`）
```
S2 curtain: P2 motor-control {0=Pause;1=Open;2=Close;3=auto}(write) ·
            P3 current-position [0,100] r · P6 status {Stopped/Opening/Closing} r ·
            P7 target-position [0,100] rw
```
注意 `dooya.curtain.m1` 的 `motor-control` 枚举顺序不同（`0=Close;1=Pause;2=Open`）——**必须按 value-list 字符串解析方向**。curtain/airer/window-opener 共享「motor-control + current/target-position」形状，一个 `CoverSpec` builder 覆盖 965+261+53 实例。

### humidifier（`zhimi.humidifier.ca4`）
```
S2: P1 on rw · P5 fan-level {Auto/Level1..3} rw · P6 target-humidity [30,80] rw ·
    P7 water-level [0,128] r
S3 environment: temperature / relative-humidity
```
`deerma.humidifier.jsq3` 增加 `fault {缺水/分水}` 与 `target-temperature`。

### water-heater（燃气 `viomi.waterheater.u19` / 电 `viomi.waterheater.e13`）
```
S2: P2 target-temperature [30,65] rw · P3 temperature r · P4 mode rw · P6 on rw
```

### bath-heater 浴霸（`viomi.bhf_light.v3`）——三个服务组合，没有主 `bath-heater` 服务
```
S2 light（灯）+ S4 ptc-bath-heater（P1 on rw · P4 target-temperature [25,35] rw）+
S5 fan-control（P2 mode {Bath/Cool/Dry} rw · P4 室温 · P5 湿度）
```
合成时必须**多服务聚合**，只认其中一个都会丢功能。

### washer（`viomi.washer.v20`）
```
S2: P1 on rw · P2 status {Idle/Busy/Paused/Fault} · P3 mode（28 个程序）rw ·
    P5 left-time r · P6 target-temperature {30/40/60/90} rw · P7 spin-speed rw
A1 start-wash · A2 pause
```

### lock（`lumi.lock.mcn002`）——为什么做不了远程开锁
```
S2 lock: P1..P6 全部 access: []（事件载荷）——零可写属性、零动作
S3 door: door-state {1=Locked;2=Unlocked;...} 只读 · S4 battery 只读
```
安全边界 = 显示门锁状态 + 电量 + 低电量告警；开锁必须走米家 App 的独立安全通道。

## 4. 实现注意（来自规格的硬约束）

1. **`fridge-chamber` 在同一规格出现两次**（siid 3 冷藏 / siid 4 冷冻）——必须按 `siid` 区分，`MiotReader.first` 按名取第一个会让冷冻室镜像冷藏室。
2. 轮询预算：`getProps` 100 属性/请求分块，浴霸这类 60 属性规格一次拉完；`requiredProps` 从 builder 自动推导，新 builder 无需额外管道。
3. 传感器类全部只读，适合并入现有 `SensorSpec`（`statusText` 已有先例：门锁守护中）。
4. `television` 开机只有 `ble-control.turn-on`，云端成功率看机型——UI 要按「关机稳、开机看运气」设计。

## 5. 建议路线

1. ✅ 已做：净化器（#98）、灯误判修复、`video-doorbell` 控制接入。
2. 短平快（复用现有 Spec/Command，改动小）：humidifier → 并入 `FanSpec`+湿度控制 或新 `HumidifierSpec`；dehumidifier 同理；传感器类并入 `SensorSpec`。
3. 中等（一个 `CoverSpec` + 位置滑块）：curtain + airer（+window-opener）。
4. 较大（多服务聚合 / 状态机类卡片）：bath-heater、washer、dishwasher、fridge（`FridgeSpec` 已存在，补 MIoT 合成）、water-heater、oven、toilet。
5. 明确不做：远程开锁、PTZ/对讲、事件型人体传感器的「有人检测」（除非引入 MIoT 事件订阅通道）。

每条引用的规格原文可在 `https://miot-spec.org/miot-spec-v2/instance?type=<urn>` 复查（人读页面 `home.miot-spec.com/spec/<model>`）。
