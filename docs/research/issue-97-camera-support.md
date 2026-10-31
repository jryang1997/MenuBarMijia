# 议题 #97 调研：米家摄像头支持与「小窗」画中画（macOS）

调研日期：2026-10-30　状态：结论已成型，未在真机验证的部分单独标注
需求原文（#97）：*「希望能增加摄像头支持，支持米家摄像头小窗口这样。这样一边看电视，可以一边看家看孩子睡觉啥」*

本文只回答三件事：**能不能看到画面**、**画面从哪条链路来**、**能看到画面之后还能顺手控制什么**。所有事实均给出一手来源；推断的地方显式标 `[推断]`。

---

## 0. 结论先行

1. **米家云端直连（`api.io.mi.com`）拿不到实时画面。** MIoT Spec 里摄像头的 `p2p-stream` 服务只声明编码参数和两个**没有入参、没有出参**的动作（`start-p2p-stream` / `stop-stream`），媒体流本来就不经过 HTTP 接口。小米官方 Home Assistant 集成在 issue 里把这条写死了：「xiaomi_home does not support getting picture or video stream from cameras. It is by design.」
2. **官方唯一的"能跑"路径是一个闭源二进制。** 小米自家 `XiaoMi/xiaomi-miloco` 仓库带着 `libmiot_camera_lite.dylib`（darwin arm64 + x86_64），走 PPCS/PPPP P2P、要求摄像头与本机同一局域网、UDP 入站，且许可证限定**非商业、不得用于开发 App**。MenuBarMijia 不能链接它。
3. **HA 后端能拿到实时画面，而且 `AVPlayer` 直接能播。** HA 把摄像头包装成 HLS：WebSocket `camera/stream` 返回 `/api/hls/<token>/master_playlist.m3u8`，该视图 `requires_auth = False`（token 在路径里），`AVPlayer` 不需要任何自定义请求头即可播放 —— 零第三方依赖成立。
4. **但米家摄像头本身进不了 HA 的 `camera.*`。** 官方 `ha_xiaomi_home` 连 `camera` 平台都没有；第三方 `al-one/hass-xiaomi-miot` 只有少数带 `camera-stream-for-google-home` 服务的型号能拿到 HLS/RTSP，其余型号给的是"事件片段 + 告警封面"，不是直播。真直播要靠 `go2rtc`（CS2/TUTK 本地 P2P）或 RTSP/ONVIF 桥。
5. **摄像头的基础控制（开关、夜视、移动侦测、指示灯、SD 卡、AI 检测开关）两边都能做**：它们都是普通 MIoT 属性（`get_properties` / `set_properties`），与视频链路无关（HA 侧取决于集成有没有把该属性映射成实体）。
6. **PTZ 方向键、双向语音做不了。** MIoT Spec 里没有方向移动动作（只有 `ptz-calibrate` 校准）；官方 miloco 文档明说「不支持 PTZ 控制或双向语音」。

分层落地建议见 §5。

---

## 1. 可行性矩阵

| 能力 | `HAWebSocketProvider`（HA） | `MiCloudProvider`（云直连） | 结论 |
| --- | --- | --- | --- |
| 实时画面 | ✅ HLS（`camera/stream`）+ `AVPlayer` | ❌ 无 HTTP 取流接口；`start-hls-stream` 仅部分型号 | Tier 1 / Tier 2 |
| 静帧/封面 | ✅ `/api/camera_proxy/<entity>?token=` | ⚠️ 仅"事件截图"，需 AES 解密 | Tier 1 / Tier 2.5 |
| 悬浮小窗 | ✅ `NSPanel` + `AVPlayerView` | 同（有 URL 即可） | Tier 1 |
| 系统画中画 PiP | ✅ `AVPictureInPictureController`（macOS 10.15+） | 同 | Tier 1（可选） |
| 开关机（`on`） | ✅（若实体暴露 `turn_on/off`） | ✅ `camera-control.on` | Tier 1 |
| 夜视/录像模式/宽动态 | ✅（若 HA 映射成 switch/select） | ✅ `camera-control.night-shot` 等 | Tier 1 |
| 移动侦测开关 | ✅ | ✅ `motion-detection.motion-detection` | Tier 1 |
| SD 卡状态/格式化 | ⚠️ 视集成 | ✅ `memory-card-management.*` | Tier 1（云侧更全） |
| AI 检测开关 | ⚠️ 视集成 | ✅ `ai-detection.*` | Tier 1（云侧更全） |
| PTZ 方向控制 | ❌ | ❌ | 不做 |
| 双向语音 | ❌ | ❌ | 不做 |
| 本地直连（不经 HA/云） | — | ❌（闭源 dylib + 非商业许可） | 不做 |

---

## 2. Mi Cloud 直连（`api.io.mi.com` + MIoT Spec）

### 2.1 MIoT Spec 对摄像头到底暴露了什么

设备类型 URN 只有两个：`urn:miot-spec-v2:device:camera:0000A01C` 与 `urn:miot-spec-v2:device:camera:0000A007`。实例清单来自官方接口
`https://miot-spec.org/miot-spec-v2/instances?status=all`（本次下载 48,111 条实例，其中 camera / cateye / video-doorbell 共 1,410 条）。

**抽样方法**：从 1,410 条摄像头实例中 `random.seed(97)` 随机抽 60 个型号，逐个拉
`https://miot-spec.org/miot-spec-v2/instance?type=<urn>`，统计服务出现频率（0 失败）：

| 服务 | 命中 | 占比 |
| --- | --- | --- |
| `camera-control` | 60/60 | 100% |
| `memory-card-management` | 56/60 | 93% |
| `motion-detection` | 55/60 | 92% |
| `p2p-stream` | 29/60 | 48% |
| `camera-stream-for-google-home` | 10/60 | 17% |
| `camera-stream-for-amazon-alexa` | 10/60 | 17% |

**具体属性（主流米家生态机型 `chuangmi.camera.81ac1`，创米/小米摄像机常见规格）**
来源：`https://miot-spec.org/miot-spec-v2/instance?type=urn:miot-spec-v2:device:camera:0000A01C:chuangmi-81ac1:1`
（人读页面：<https://home.miot-spec.com/spec/chuangmi.camera.81ac1>）

`camera-control`（siid=2，该实例共 10 个属性，下表列 7 个常用项）：

| piid | 属性 | 格式 | 访问 |
| --- | --- | --- | --- |
| 1 | `on` | bool | read,write,notify |
| 2 | `image-rollover` | uint16 | read,write,notify |
| 3 | `night-shot` | uint8（0 Off / 1 On / 2 Auto / 3 Auto Full Color / 4 On Full Color / 5 Auto Smart Full Color） | read,write,notify |
| 4 | `time-watermark` | bool | read,write,notify |
| 7 | `recording-mode` | uint8（0 No Record / 1 Motion / 2 All） | read,write,notify |
| 10 | `ptz-camera` | bool | read,notify（只读，说明"是不是云台"，不是方向控制） |
| 14 | `image-distortion-correction` | bool | read,write,notify |

`motion-detection`（siid=5）：`motion-detection`(bool rw)、`alarm-interval`、`detection-sensitivity`、`motion-detection-start-time` / `-end-time`(string rw)。
`ai-detection`（siid=8）：`face-detection-switch`、`pet-detection-switch`、`hand-gesture-detection-switch`、`human-detection`、`move-detection`、`babycry-detection-switch`、`sound-detection-switch`、`pet-tracking` 等。

这些全是普通属性，`get_properties` / `set_properties` 就能读写 —— 现有 `MiCloudClient` 已具备该能力（`getProps` → `miotspec/prop/get`，`Sources/MijiaCore/MiCloud/MiCloudClient.swift:340-350`；`setProps` → `miotspec/prop/set`，`:368-376`）。

**SD 卡（`lumi.camera.agl011` 为例）**：`memory-card-management` 有 `status`、`storage-total-space`/`-free-space`/`-used-space`、`remaining-recording-duration`，动作 `format`、`pop-up`。

**关键缺口 —— PTZ 没有方向动作**：`lumi.camera.agl011` 的 `camera-control` 只有 `ptz-calibrate`、`restart-device`、`linkage-calibrate` 三个零参动作，没有上下左右。`go2rtc` 的 MISS 客户端里还留着 `dafangLeft/Right/Up/Down` 的注释代码（`pkg/xiaomi/miss/client.go:320-336`），说明方向控制历史上走的是 P2P 私有指令，不在 MIoT 里。

### 2.2 实时画面为什么拿不到：`p2p-stream` 的动作是空壳

`urn:miot-spec-v2:device:camera:0000A01C:lumi-agl011:1` 的 `p2p-stream`（siid=9）：

```
P 1 talk-mode          uint8  read,notify   [0 Two-way, 1 One-way]
P 2 audio-codec        uint8  read,notify   [0 G711A, 1 ACC, 2 OPUS, 3 PCM]
P 4 video-codec        uint8  read,notify   [0 H264, 1 H265]
P 10 resolution-types  uint8  read,notify   [0 360 … 5 1440]
A 1 start-p2p-stream   in=[]  out=[]
A 2 stop-stream        in=[]  out=[]
A 3 upload-video       in=[]  out=[]
```

动作没有任何入参/出参 —— 它只是给设备发一个"开始推 P2P"的信号，**媒体平面完全在 MIoT/HTTP 之外**。这就是"云直连拿不到画面"的规格层证据。

社区实现也印证同样的结论：

- **小米官方 HA 集成 `XiaoMi/ha_xiaomi_home`（v0.5.0，commit `75b3acb`）根本没有 camera 平台。**
  平台文件只有 `binary_sensor / button / climate / cover / device_tracker / event / fan / humidifier / light / media_player / notify / number / select / sensor / switch / text / vacuum / water_heater`（`custom_components/xiaomi_home/`）。
  Spec→实体的转换表只覆盖 `binary_sensor / cover / dehumidifier / device_tracker / fan / heater / humidifier / light / sensor / television / thermostat / vacuum / water_heater`（`custom_components/xiaomi_home/miot/specs/specv2entity.py`），`camera-control`、`p2p-stream` 在这些文件里**一次都没出现**（全仓库 `grep -rni camera --include=*.py` 只命中 `tools/update_lan_rule.py` 的型号字符串）。
- 维护者（小米）原话，issue #40 评论：**"xiaomi_home does not support getting picture or video stream from cameras. It is by design."**
  <https://github.com/XiaoMi/ha_xiaomi_home/issues/40#issuecomment-2547523405>
- issue #160 评论：**"这2个button只是依据 MIoT-Spec-V2 生成的实体，xiaomi_home不支持查看摄像头视频。"**
  <https://github.com/XiaoMi/ha_xiaomi_home/issues/160#issuecomment-2551217420>
- issue #1265「摄像头视频流相关功能」开单 5 分钟后被关，无评论：<https://github.com/XiaoMi/ha_xiaomi_home/issues/1265>
- 另有 #872（添加摄像头成功后 HA 显示没有设备或实体）、#1043（摄像头设备列表里看不到）仍开着。

### 2.3 小米自己的"官方实现"：闭源 dylib（不可用）

`XiaoMi/xiaomi-miloco`（commit `a48c181`，2026-10-16）是小米开源的"用米家摄像头做全模态感知"，**它确实能在 macOS 上拿到实时画面**，但方式是链接自家二进制：

- `backend/miot/src/miot/libs/darwin/arm64/libmiot_camera_lite.dylib`
- `backend/miot/src/miot/libs/darwin/x86_64/libmiot_camera_lite.dylib`
- （Linux `.so`、Windows DLL 的加载分支写在 `backend/miot/src/miot/camera.py` 的 `_load_dynamic_lib()`，但仓库只带 darwin/linux 产物）

Python 侧通过 `ctypes` 调用 C ABI：`miot_camera_init(host, client_id, access_token)`（`camera.py:960-964`）、`miot_camera_register_raw_data`、`miot_camera_start`，回调里拿到 H.264/H.265 裸帧再自行解码。`start_async(...)` 还带一个 `pin_code` 参数（`camera.py:197-203`）——即部分机型的局域网直连需要设备 PIN。

`knowledge/03-features/live-camera-view.md` 写死了能力边界：

> 实时观看依赖摄像头与 Miloco 服务在同一局域网；**PPCS P2P 连接需要 UDP 入站**……不支持 PTZ 控制或双向语音……不支持跨局域网/公网访问。

许可证（`LICENSE.md`）限定为**个人、非商业**用途，并明确「未授权您开发应用程序（APP）、Web 服务或其他形式的软件」。README 里还记着一次翻车：2026-08-06 的 hotfix 撤回了"摄像头 IP 直连"，因为**捆绑的 native library 会让部分老机型 SIGSEGV**。

结论：MenuBarMijia 既不能分发这个 dylib，也不能把它当稳定依赖。**排除。**（官方 Windows PC 客户端 `MiCamera.exe` 的逆向结果见 §8：同一结论。）

### 2.4 有没有"合规"的云侧取流？有，但只对 17% 型号

MIoT Spec 里确实定义了给 Google Home / Alexa 投屏用的服务：

`camera-stream-for-google-home`（siid=20）：
```
A 3 start-hls-stream  in=[video_codec_type, video_attribute, audio_codec_type, audio_attribute]
                      out=[stream_address, stream_receiver_id, stream_auth_token, expiration_time]
A 1 get-stream-configuration out=[stream_status, video_codec_type, video_attribute, audio_codec_type, audio_attribute]
A 4 stop-stream
```
`camera-stream-for-amazon-alexa`（siid=19）：
```
A 2 start-rtsp-stream in=[authorization_type, video_codec_type, video_attribute, audio_codec_type, audio_attribute]
                      out=[stream_address, image_snapshot, expiration_time]
P 11 webrtc-offer (string)
A 4 initiate-webrtc-session
```

也就是说：**型号支持的话，一次 `action` 调用就能换回一个带过期时间的流地址**。`MiCloudClient.action(_:)`（`Sources/MijiaCore/MiCloud/MiCloudClient.swift:380`）已经能发这个请求，`MiotActionCall` 已有 `siid/aiid/in`（同文件 `:74-84`），理论上加几十行就能拿到 `out`。

但这条路有三个硬约束：

1. **覆盖率**：60 型号抽样里只有 10 个（17%）带这个服务，且集中在 `chuangmi.camera.*`、`lumi.camera.*`、`xiaomi.camera.*` 的部分型号；另外单独查过的 3 个 `mijia.camera.*` 型号（`tony` / `spec` / `1`）都没有该服务，只有 `camera-control` + `memory-card-management` + `motion-detection`。
2. **服务端会 403**：`al-one/hass-xiaomi-miot` 的实现里明确处理这条路径（`custom_components/xiaomi_miot/camera.py:369-389` 选 `camera_stream_for_google_home` / `camera_stream_for_amazon_alexa`、`:489` 调 `start_hls_stream` 拿 `stream_address`），而维护者在 issue #928 里的原话是「**小米视频流服务器有时会拒绝请求，对此无能为力**」（日志 `Server returned 403 Forbidden`）：<https://github.com/al-one/hass-xiaomi-miot/issues/928>
3. **有时效**：`expiration_time` 决定 URL TTL，第三方实现里缺省按 4.5 分钟兜底刷新（`camera.py:499-507`）。

`[推断]` 我无法验证"2026 年 CN 账号 + 特定机型"下这个动作的实际成功率；它属于**可做但不可承诺**的能力，必须按"尽力而为 + 明确失败提示"设计，不能作为产品主路径。

### 2.5 另一条云侧路径：事件截图（录像片段）

`al-one` 的实现还揭示了小米云的另一组接口（`custom_components/xiaomi_miot/camera.py`）：

- 告警列表：`business.smartcamera.api.io.mi.com` → `miot/camera/app/v1/alarm/playlist/limit`（`:184`）、`common/app/get/eventlist`（`:212`）
- 片段 HLS：同一 host → `common/app/m3u8`，附带 `yetAnotherServiceToken=<serviceToken>`（`:241-255`）
- 事件封面：`processor.smartcamera.api.io.mi.com` → `miot/camera/app/v1/img`，请求里带 `segmentIv`（客户端生成的 16 字节随机 IV），返回的是 **AES-CBC 密文**，需要用 `ssecurity` 解 base64 后当 key 才能解出 JPEG（`:257-274`，ffmpeg 参数 `-decryption_key <hex(ssecurity)> -decryption_iv <iv>`）

MenuBarMijia 的 `MiSession` 里已经有 `ssecurity` 与 `serviceToken`（`Sources/MijiaCore/MiCloud/MiAccountLogin.swift:22-23`），RC4 签名链路也已实现。所以"最近一次告警的封面图 + 10 秒片段"在技术上可落地，**但它不是直播**，且依赖账号的云存储/事件服务。列为 Tier 2.5。

---

## 3. Home Assistant 后端（`HAWebSocketProvider`）

### 3.1 HA 怎么暴露摄像头

HA 的 `camera` 是"building block"集成，一个实体同时提供**静帧**和**（可选）直播**（<https://developers.home-assistant.io/docs/core/entity/camera/>）。要直播必须实现 `stream_source` 并声明 `CameraEntityFeature.STREAM`。

**（a）静帧 —— `GET /api/camera_proxy/<entity_id>`**
`homeassistant/components/camera/__init__.py:373`：

```python
class CameraImageView(CameraView):
    url = "/api/camera_proxy/{entity_id}"
```
- 支持 `?width=` / `?height=` 缩放（同文件 `:378-383`）。
- 鉴权：`CameraView.requires_auth = False`（`:329`），实际靠 `?token=` 查询参数或 Bearer/会话 cookie；token 取自 `camera.access_tokens`（`:344`）。
- **这个 token 就在实体状态属性里**：`CameraEntityStateAttribute.ACCESS_TOKEN = "access_token"`（`components/camera/const.py:49`），`state_attributes` 直接返回 `self.access_tokens[-1]`（`components/camera/entity.py:383`），`entity_picture` 拼成 `/api/camera_proxy/{entity_id}?token={token}`（`const.py:18` + `entity.py:181`）。
- 对 MenuBarMijia 的意义：`HAWebSocketProvider` 已经订阅 `get_states`（`Sources/MijiaCore/HomeProvider.swift:141`），**camera 实体的 `access_token` 会免费送到手上**，拼 URL 不需要额外请求。

**（b）MJPEG —— `GET /api/camera_proxy_stream/<entity_id>`**
`components/camera/__init__.py:397`：

```python
class CameraMjpegStream(CameraView):
    url = "/api/camera_proxy_stream/{entity_id}"
```
- 不带 `interval` 时走 `camera.handle_async_mjpeg_stream(request)`；不支持原生 MJPEG 的集成返回 `None` → `HTTPBadGateway`（`:403-410`）。
- 带 `?interval=0.5` 时由 HA 用静帧合成 MJPEG（`handle_async_still_stream`），最小间隔 `MIN_STREAM_INTERVAL = 0.5`（`components/camera/const.py:20`）。`frame_interval` 默认也是 0.5 秒。

**（c）HLS —— WebSocket `camera/stream`**
`components/camera/__init__.py:441-459`：

```python
@websocket_api.websocket_command({
    "type": "camera/stream",
    "entity_id": cv.entity_id,
    "format": probatio.Optional("format", default="hls"): probatio.In(OUTPUT_FORMATS),
})
...
url = await async_stream_endpoint_url(hass, camera, fmt=msg["format"])
connection.send_result(msg["id"], {"url": url})
```
- `OUTPUT_FORMATS = ["hls"]`（`components/stream/const.py:15`）—— **只有 HLS，没有别的格式**。
- 返回的 URL 形如 `/api/hls/{token}/master_playlist.m3u8`（`components/stream/hls.py:118`），token 是 `secrets.token_hex()`（`components/stream/__init__.py:365`）。
- 关键：`StreamView.requires_auth = False`（`components/stream/core.py:378`），**鉴权就是那个不可猜的路径 token**，不需要请求头。
- 分段是 fMP4（`SEGMENT_CONTAINER_FORMAT = "mp4"`，`components/stream/const.py:17`），非低延迟模式目标片长 2 秒（`:28`）。

**（d）配套命令**
- `camera/capabilities`（`:423`）返回 `frontend_stream_types`（HLS / WEB_RTC），可用于判断该实体能不能播。
- `camera/get_prefs` / `camera/update_prefs`（`:478`、`:493`）控制 preload 与旋转。
- `camera/webrtc/offer`（`components/camera/webrtc.py:252-254`）—— 原生 WebRTC 播放需要 Google WebRTC 框架，**零依赖 Swift 做不到**，本仓库不考虑。
- 若需要给 `AVPlayer`/`AsyncImage` 之外的客户端签名路径，可用 WS `auth/sign_path`（`components/auth/__init__.py:773-795`，参数 `path`、`expires` 默认 30 秒）。

### 3.2 米家摄像头今天怎么进 HA

| 路径 | 能否出实时画面 | 一手依据 |
| --- | --- | --- |
| 官方 `XiaoMi/ha_xiaomi_home` | ❌ 无 camera 平台 | `#40` 维护者原话；`specv2entity.py` 无 camera 映射 |
| `al-one/hass-xiaomi-miot` | ⚠️ 部分型号（`start_hls_stream` / `start_rtsp_stream`），其余只有告警片段 | `camera.py:369-389`、issue `#928` |
| `AlexxIT/go2rtc`（本地 P2P → HLS/RTSP/WebRTC） | ✅ | `internal/xiaomi/README.md`、`pkg/xiaomi/miss/*` |
| ONVIF/RTSP 桥（NAS、NVR） | ✅（设备本身要能出 RTSP） | 设备能力问题，非软件问题 |

`go2rtc` 的 `internal/xiaomi/README.md` 是理解米家摄像头协议最好的公开材料（原文引用）：

> Since 2020, Xiaomi has introduced a unified protocol for cameras called `miss`. I think it means **Mi Secure Streaming**. …… go2rtc supports two formats: `xiaomi/mess` and `xiaomi/legacy`. And multiple P2P protocols: `cs2+udp`, `cs2+tcp`, several versions of `tutk+udp`. ……
> 1. **Not all cameras are supported**. The list of supported cameras is collected in [this issue].
> 2. Each time you connect to the camera, you need Internet access to obtain encryption keys.
> 3. Connection to the camera is local only.

（原文的 `[this issue]` 指 go2rtc issue #1982；`xiaomi/mess` 是 README 里的笔误，同一仓库代码里协议名是 `miss`，见 `pkg/xiaomi/miss/`。）

信令部分的代码证据（这就是"密钥来自小米云"的具体形态）：

- `internal/xiaomi/xiaomi.go:152-196` `getMissURL()`：`POST /v2/device/miss_get_vendor`，body `{"app_pubkey":…,"did":…,"support_vendors":"TUTK_CS2_MTP"}`，返回 `vendor`（`1=tutk, 3=agora, 4=cs2, 6=mtp`，见 `:203` 附近 `getVendorName`）、`public_key`、`sign`。
- `internal/xiaomi/xiaomi.go:110-149` `getLegacyURL()`：`POST /device/devicepass`，body `{"did":…, "toSignAppData":<客户端公钥 hex>}`，返回 `p2p_id`（TUTK UID）、`password`、`p2p_dev_public_key`、`signForAppData`。
- 两者都跑在 `https://<region>.api.io.mi.com/app`（`:356` `GetBaseURL`）——**正是 MenuBarMijia 已经实现的 RC4 签名接口**。
- 之后是 MISS 握手：`pkg/xiaomi/miss/client.go:107-124` 发 `{"public_key":…,"sign":…,"uuid":"","support_encrypt":0}`，成帧用 `crypto.Encode(data, key)`（`:130`），再 `StartMedia(channel, quality, audio)`（`:147`）。

也就是说：**信令可做（云接口现成），媒体平面不做**（要实现 CS2/TUTK + DTLS + H.264/H.265 解包 + 音视频同步，等于重写 go2rtc 的 `pkg/tutk` 与 `pkg/xiaomi/miss`）。

`python-miio` 从另一个角度印证"本地也没有 RTSP"：`miio/integrations/chuangmi/camera/chuangmi_camera.py` 只暴露开关、移动侦测、指示灯、翻转、水印、WDR 等；`miio/integrations/lumi/camera/aqaracamera.py` 则直接暴露 `p2p_id`、`av_id`、`av_password` 三个属性——本地 miIO 层面能拿到的只是 P2P 凭证，不是流地址。

---

## 4. macOS 小窗 / 画中画

### 4.1 `AVPlayer` 能播什么

Apple 对 `AVPlayer` 的定位（<https://developer.apple.com/documentation/avfoundation/avplayer>）：

> Use an instance of `AVPlayer` to play local and remote file-based media, such as QuickTime movies and MP3 audio files, **as well as audiovisual media served using HTTP Live Streaming**.

即：**HLS 是官方支持的远程流格式**；AVFoundation 里没有 RTSP 客户端，也没有私有 P2P 的解复用器。所以：

- ✅ HA 的 `/api/hls/<token>/master_playlist.m3u8`（fMP4 分段）→ `AVPlayer(url:)` 直接播。
- ❌ 小米的 `start-rtsp-stream` 即使拿到 RTSP 地址也播不了（要自己实现 RTP/RTSP，等于引入 FFmpeg）。
- ❌ CS2/TUTK 裸流播不了（除非自己解包成 `CMSampleBuffer` 喂 `AVSampleBufferDisplayLayer`，但那仍需 P2P 实现）。

ATS 不是障碍：`scripts/build_app.sh:151-155` 已经写入 `NSAllowsArbitraryLoads` + `NSAllowsLocalNetworking`，`http://192.168.x.x/api/hls/...` 可直连（Apple 文档说明这两个键分别放行任意加载与本地/IP 直连：<https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking>）。

**证书是另一个坑**：`AVPlayer` 的 HTTPS 加载由系统媒体栈完成，App 无法像 `URLSession` 那样用 `urlSession(_:didReceive challenge:)` 注入信任例外（`AVAssetResourceLoader` 只能接管自定义 scheme 的请求）。若用户的 HA 用自签 HTTPS，HLS 会失败。`[推断]` 现有 HA 链路也没有自签放行逻辑（`HomeProvider.swift:101-105` 只置空代理、设 120s 超时），所以这不是新增限制；但 UI 上要把"证书不受信任"和"摄像头不支持"区分开。

### 4.2 系统画中画（PiP）

- `AVPictureInPictureController`（macOS **10.15+**）："A controller that responds to user-initiated Picture in Picture playback of video in a floating, resizable window." <https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller>
  - 用 `init(playerLayer:)` 从 `AVPlayerLayer` 创建；
  - `isPictureInPictureSupported()` 判断设备是否支持（macOS 10.15+）；
  - `startPictureInPicture()` / `stopPictureInPicture()`、`isPictureInPicturePossible`。
- `AVPlayerView`（macOS 10.9+）自带 `allowsPictureInPicturePlayback`（macOS 10.15+），不用自己拼 layer：<https://developer.apple.com/documentation/avkit/avplayerview/allowspictureinpictureplayback>

`[推断]` PiP 适合"用户主动点一下进系统级小窗"；但 issue #97 要的是"一边看电视一边看家"，PiP 会被全屏播放器接管、位置也不完全由 App 控制，体验不如自绘悬浮面板。

### 4.3 自绘悬浮小窗（推荐主路径）

用 `NSPanel` 而不是 `NSWindow`，因为它"typically performs a function that is auxiliary to the main window"（<https://developer.apple.com/documentation/appkit/nspanel>）。需要三个属性组合：

| API | 作用 | 文档 |
| --- | --- | --- |
| `panel.level = .floating` | 浮在普通窗口之上（"Useful for floating palettes"） | <https://developer.apple.com/documentation/appkit/nswindow/level-swift.struct/floating> |
| `panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` | 跟随所有桌面空间；可显示在全屏 App 之上（"The window can appear in all spaces"，macOS 10.5+） | <https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces> |
| `styleMask.insert(.nonactivatingPanel)` | 点小窗不抢走当前 App 的焦点（"does not activate the owning app"），看电视/打字时点它不会切走 | <https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel> |

仓库里已有同类实现可复用：`Sources/MenuBarMijiaApp/MenuBarPanelController.swift:327-345` 的 `makePanel()`（`level = .statusBar`、`collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]`）。小窗只是换一组 level/collectionBehavior。

### 4.4 MJPEG / 静帧：自己解析，不要指望 `WKWebView`

- 纯 AppKit 路线：`URLSession.bytes(for:)` 读 `multipart/x-mixed-replace`，按 `boundary` 切分，每段 `NSImage(data:)`。约百行，零依赖。
- `WKWebView` + `<img>` 播 MJPEG 不在 Apple 文档承诺范围内，WebKit 侧历史 bug（如 <https://bugs.webkit.org/show_bug.cgi?id=36536>）说明边界行为不稳定；`[推断]` 也不值得为一个"小窗"背一个 WebView。
- 若要低功耗：对"只是看着"的场景，1 fps 的 `/api/camera_proxy?token=` 轮询（或 `camera_proxy_stream?interval=1`）比持续解码 HLS 省电得多，`AVPlayer` 只在用户点"放大/实时"时才起。

---

## 5. 分层落地方案

### Tier 1（可做，零第三方依赖，建议先做）

**目标**：HA 用户能开一个悬浮小窗看摄像头，并顺手控制摄像头的基础属性。

1. **数据层**：`HAHomeSnapshot` 已经拿到 `camera.*` 实体与状态，`DeviceSynthesizer` 目前在 `Sources/MijiaCore/DeviceSynthesizer.swift:255-258` 只放行 `light./climate./fan./vacuum./switch./media_player./sensor.`，camera 被丢弃。`DeviceKind`（`Sources/MijiaCore/Models.swift:327-337`）也没有 camera 分支。建议在 `HomeStore` 里旁挂一个 `CameraCatalog`（或加 `DeviceKind.camera(CameraSpec)`），不要改动现有设备卡片的语义。
2. **取流**：WS `camera/stream` → 若 `frontend_stream_types` 含 HLS，`AVPlayer` 播放返回的相对路径拼上 `baseURLString`；失败回落到静帧轮询。
3. **小窗**：`NSPanel`（§4.3）+ `AVPlayerView`；窗口位置/大小记进 `UserDefaults`；可拖拽、可缩放、可"钉住"。
4. **失败可见**：`camera/stream` 会返回 `start_stream_failed`（`components/camera/__init__.py:459-476`），要把它翻成中文错误而不是静默黑屏。
5. **控制**：HA 侧能映射多少用多少（`turn_on`/`turn_off`、`camera.enable_motion_detection` 等 action 见 <https://www.home-assistant.io/integrations/camera/>）。

**Tier 1 的诚实边界**：画面来自 HA，**不是**来自米家云。没有 go2rtc/RTSP 桥的纯米家用户，Tier 1 只能看到"HA 里已经存在的摄像头"，而官方 `xiaomi_home` 集成不会给他们任何 `camera.*` 实体。

### Tier 1b（云直连也能做：只做"控制"，不做"画面"）

`MiCloudProvider` 侧把摄像头的 MIoT 属性接进现有 `MiotSynthesizer`：

- `camera-control`：`on`（开关机）、`night-shot`（夜视模式）、`recording-mode`、`image-rollover`、`wdr-mode`、`human-tracking`
- `motion-detection`：开关 + 灵敏度 + 时间段
- `memory-card-management`：容量/剩余/状态（`format` 动作风险高，需二次确认）
- `ai-detection`：人脸/宠物/哭声/手势等开关

这些是标准属性，`MiotSpec.swift` 已能解析 `services/properties/actions`（`MiotSpec.swift:109-119`），`MiCloudClient` 也已具备 `prop/get`、`prop/set` 与 `action`（`:340-350`、`:368-376`、`:380`）。工作量主要在"哪些属性该显示成什么控件"的映射，以及 `camera-control` 与其它服务重名属性（如多个 `detection-sensitivity`，`chuangmi.camera.81ac1` 的 `ai-detection` 里 piid 22/23 同名）的消歧。

### Tier 2（尽力而为，不可承诺）

1. **`start-hls-stream` 直取云侧 HLS**：仅 17% 抽样型号有该服务；403 与过期是常态；需要"拿不到就明确说型号不支持"。
2. **事件截图/片段**（§2.5）：`alarm/playlist` + `img`（AES-CBC 解密）+ `m3u8`。用于"通知里带一张图"。

### Tier 3（不做，写清楚为什么）

- **MISS/CS2/TUTK P2P 直连**：无公开协议、需 UDP 入站、必须联网取密钥、成功率依赖机型（go2rtc 自己都列了"不支持清单"）。等于在 Swift 里重写一个 go2rtc。
- **链接小米官方 `libmiot_camera_lite.dylib`**：闭源、非商业许可、历史上会把老机型搞崩（miloco README 2026-08-06 条目），且与"零第三方依赖 + 可审计"的仓库原则冲突。
- **PTZ 方向键 / 双向语音**：MIoT 无对应动作，官方实现也不提供。

### Windows 端

按 [ADR-0006](../adr/0006-dual-platform-implementation.md)，两端各自实现。HA 侧协议完全相同（同一套 WebSocket/REST）；渲染侧 Windows 没有等价物：Chromium/WebView2 不原生支持 HLS（要用 hls.js 之类基于 MSE 的播放器，或 ffmpeg 侧车 + 自绘）。这不在本议题范围内，但**不要在 macOS 侧承诺"两端一致"**。

---

## 6. 待验证 / 已知不确定

| 项 | 状态 |
| --- | --- |
| 真机 `camera/stream` → `AVPlayer` 播放米家摄像头（经 go2rtc） | 未验证（本次无 HA 实例与摄像头） |
| `start-hls-stream` 在 2026 年 CN 账号 + 具体型号的成功率 | 未验证；第三方实现存在且会 403 |
| 米家云 HLS 的编码（H.264/H.265）与 `AVPlayer` 兼容性 | 未验证；若为 H.265 且封装非标，`AVPlayer` 可能拒播 |
| 事件封面 AES key 是否恒为 `base64(ssecurity)` | `[推断]`，从 `al-one` 的 ffmpeg 参数反推，未实机解过 |
| `LSUIElement` 菜单栏 App 使用系统 PiP 的观感 | 未验证；`[推断]` 不如自绘面板 |

---

## 7. 参考（一手来源）

**MIoT Spec**
- 实例清单：<https://miot-spec.org/miot-spec-v2/instances?status=all>
- `chuangmi.camera.81ac1`：<https://miot-spec.org/miot-spec-v2/instance?type=urn:miot-spec-v2:device:camera:0000A01C:chuangmi-81ac1:1>（人读：<https://home.miot-spec.com/spec/chuangmi.camera.81ac1>）
- `chuangmi.camera.ipc019`（同时有 google-home / alexa / p2p 三个服务）：<https://miot-spec.org/miot-spec-v2/instance?type=urn:miot-spec-v2:device:camera:0000A01C:chuangmi-ipc019:1>
- `lumi.camera.agl011`（服务最全，含 webrtc-offer）：<https://miot-spec.org/miot-spec-v2/instance?type=urn:miot-spec-v2:device:camera:0000A01C:lumi-agl011:1>

**小米官方 HA 集成**（`75b3acb`，v0.5.0）
- <https://github.com/XiaoMi/ha_xiaomi_home>（无 `camera.py`；`custom_components/xiaomi_home/miot/specs/specv2entity.py` 无 camera 映射）
- #40 "not support … by design"：<https://github.com/XiaoMi/ha_xiaomi_home/issues/40#issuecomment-2547523405>
- #160 "xiaomi_home不支持查看摄像头视频"：<https://github.com/XiaoMi/ha_xiaomi_home/issues/160#issuecomment-2551217420>
- #1265 被关的取流请求：<https://github.com/XiaoMi/ha_xiaomi_home/issues/1265>

**小米 miloco**（`a48c181`）
- <https://github.com/XiaoMi/xiaomi-miloco>
- `backend/miot/src/miot/camera.py`（ctypes 绑定、`miot_camera_init`、`pin_code`）
- `knowledge/03-features/live-camera-view.md`（PPCS、UDP 入站、无 PTZ/双向语音）
- `LICENSE.md`（非商业、禁止用于开发 App）

**go2rtc**（`7c05066`）
- `internal/xiaomi/README.md`（MISS 协议、cs2/tutk、每次连接需联网取密钥）
- `internal/xiaomi/xiaomi.go:110-196`（`/device/devicepass`、`/v2/device/miss_get_vendor`）
- `pkg/xiaomi/miss/client.go:107-147`（握手与 `StartMedia`）
- `pkg/tutk/`（DTLS/IOTC 实现）

**hass-xiaomi-miot**（`6df83d6`）
- `custom_components/xiaomi_miot/camera.py:184-274`（告警列表/m3u8/img + AES 参数）、`:369-389`（google-home / alexa 取流）、`:452-507`（`stream_source` → `start_hls_stream` 与过期时间）
- #928 403：<https://github.com/al-one/hass-xiaomi-miot/issues/928>

**python-miio**（`9a00e08`）
- `miio/integrations/chuangmi/camera/chuangmi_camera.py`（只有状态/开关类命令）
- `miio/integrations/lumi/camera/aqaracamera.py`（暴露 `p2p_id` / `av_id` / `av_password`）

**Home Assistant core**（`0338309`）
- 静帧：`components/camera/__init__.py:329`（`requires_auth = False`）、`:373`（`/api/camera_proxy/{entity_id}`）
- MJPEG：`components/camera/__init__.py:397`、`:404-419`（`interval` 静帧合成）、`components/camera/const.py:20`（`MIN_STREAM_INTERVAL = 0.5`）
- HLS：`components/camera/__init__.py:441-459`（`camera/stream`）、`components/camera/helper.py:49-63`、`components/stream/hls.py:118`、`components/stream/core.py:371-378`、`components/stream/const.py:15-28`
- Token：`components/camera/const.py:18`（`ENTITY_IMAGE_URL`）、`:46-52`（`access_token`）、`components/camera/entity.py:165,181,383,402`
- 签名路径：`components/auth/__init__.py:773-795`（`auth/sign_path`）
- WebRTC：`components/camera/webrtc.py:252-254`（`camera/webrtc/offer`）

**Apple**
- `AVPlayer`（HLS 支持）：<https://developer.apple.com/documentation/avfoundation/avplayer>
- `AVPictureInPictureController`（macOS 10.15+）：<https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller>
- `AVPlayerView.allowsPictureInPicturePlayback`（macOS 10.15+）：<https://developer.apple.com/documentation/avkit/avplayerview/allowspictureinpictureplayback>
- `NSPanel` / `.floating` / `.canJoinAllSpaces` / `.nonactivatingPanel`：<https://developer.apple.com/documentation/appkit/nspanel>
- ATS 本地网络：<https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking>

**仓库内**
- `Sources/MijiaCore/HomeProvider.swift:71`（`HAWebSocketProvider`，ephemeral URLSession、超时 120s）
- `Sources/MijiaCore/DeviceSynthesizer.swift:255-258`（当前只放行 7 类实体）
- `Sources/MijiaCore/MiCloud/MiotSpec.swift:109-159`（`services/properties/actions` 与 `shortName`）
- `Sources/MijiaCore/MiCloud/MiCloudClient.swift:340-350,368-376,380`（`prop/get`、`prop/set`、`action`）
- `Sources/MijiaCore/MiCloud/MiAccountLogin.swift:22-23`（`ssecurity`、`serviceToken`）
- `Sources/MenuBarMijiaApp/MenuBarPanelController.swift:327-345`（既有 `NSPanel` 配置）
- `scripts/build_app.sh:151-155`（ATS 放行）

---

## 8. IMICamera（创米看家助手 PC 端）逆向分析

目的：验证「官方 PC 客户端是不是有一条更省事的取流路径（RTSP/HLS/明文接口）」，以及「它的协议是不是比 go2rtc 已知的更多」。
结论先说：**没有。** 官方 PC 客户端就是 `serviceLogin → api.io.mi.com → /device/devicepass → TUTK IOTC/AVAPIs`，视频只在 P2P 里，UI 端用 FFmpeg 软解。协议细节与 `AlexxIT/go2rtc` **完全对得上**，go2rtc 反得还更彻底。

### 8.1 样本与可得性

| 来源 | 结果 |
| --- | --- |
| `https://portal.cdn.imilab.com/static/upload/20220909/IMICamera_setup.1.7.9.2.exe` | **404**（`Content-Type: application/xml`，428 字节的 OSS 错误体），文件已被 CDN 删除 |
| `https://www.imilab.com` 及 `/service/apps` | 本机连接失败（curl 超时/无法建立连接），**无法确认 1.7.9.2 是否有 macOS 版** |
| `http://miuirom.xiaomi.com/rom/u491047765/1.0.12060.2/MiCamera-1.0.12060.2.exe` | **200**，51,872,712 字节，`Content-Type: application/zip` —— 本次分析样本 |

样本信息（可复现）：

- 安装包标题：`米家智能摄像机 1.0.12060`，Inno Setup 数据版本 5.5.7
- 安装包 SHA-256：`e085bad771b3dbb48af549bb4f54194dbf466365c8f7740e657c693eb4766438`
- `app\MiCamera.exe`：2,537,912 字节，PE32（i386），SHA-256 `1ee73b395b0359d2d39dc0402a4d27072a005c1b26afc3ebfe438ce5ec04240d`，`TimeDateStamp` = 2018-12-06T14:43:42Z
- 解包：`innoextract 1.9 -e -d extract MiCamera-1.0.12060.2.exe`（`innoextract.exe` 需在 `cmd.exe` 里运行，MSYS bash 直接调用会报 command not found）

> 注：1.7.9.2 未取得，因此无法证明新版是否已改用 MISS/CS2。但 8.5 的结论只依赖"视频走 P2P、不走 HTTP"这一条，换协议不改变结论。

### 8.2 关键文件

| 文件 | 大小 | 作用 |
| --- | --- | --- |
| `app\IOTCAPIs.dll` | 236,984 | **TUTK IOTC P2P SDK**，100 个导出（`IOTC_Connect_ByUID`、`IOTC_Connect_ByUID_Parallel`、`IOTC_Session_Check`、`IOTC_Check_Device_On_Line`…） |
| `app\AVAPIs.dll` | 159,672 | **TUTK AV 流 SDK**，89 个导出（`AVAPI2_ClientConnect`、`AVAPI2_ClientSetAVTimeSync`…） |
| `app\RDTAPIs.dll` | 107,960 | TUTK RDT 数据通道，17 个导出（`RDT_Create/Write/Read`） |
| `app\P2PTunnelAPIs.dll` | 111,032 | TUTK 端口映射隧道，24 个导出 —— **安装包里没有任何二进制引用它**（`MiCamera.exe` 与全部 DLL 的字符串里 0 次命中），属于捆绑冗余 |
| `app\libsodium.dll` | 283,064 | X25519 + ChaCha20（应用层加密） |
| `app\avcodec-57.dll` 等 | 24.5 MB + 2.0/4.3/5.2/0.7/0.3 MB | FFmpeg 3.x（avcodec/avdevice/avfilter/avformat/avutil/swscale/swresample）软解 |
| `app\libcef.dll` + `*.pak` | 46.7 MB | CEF，只用来打开小米账号登录页 |
| `app\Qt5Core/Gui/Widgets/Network/Multimedia/Svg.dll` | — | Qt5 界面与网络 |
| `app\html\scripts\miaccount.js` | 19.1 KiB | **纯样式**（改登录页宽高、隐藏页脚），不含登录逻辑 |
| `app\libeay32.dll` / `ssleay32.dll` | 1.21 MB / 290 KB | OpenSSL 1.0（`MiCamera.exe` 以序号导入 9 个函数） |

### 8.3 PE 导入表（逐函数证据）

`MiCamera.exe` 的导入表（自写 PE 解析，非字符串猜测）：

```
IOTCAPIs.dll : IOTC_Initialize2, IOTC_Connect_ByUID_Parallel, IOTC_Get_SessionID,
               IOTC_Session_Check, IOTC_Session_Get_Free_Channel, IOTC_Session_Close,
               IOTC_Connect_Stop_BySID, IOTC_DeInitialize
AVAPIs.dll   : avInitialize, avDeInitialize, avClientStart2, avClientStop,
               avClientSetMaxBufSize, avSendIOCtrl, avRecvIOCtrl,
               avRecvFrameData2, avRecvAudioData
RDTAPIs.dll  : RDT_Initialize, RDT_Create, RDT_Write, RDT_Read, RDT_Destroy, RDT_DeInitialize
libsodium.dll: sodium_init, crypto_box_keypair, crypto_box_beforenm, crypto_stream_chacha20_xor
```

其它导入：`avcodec-57`、`avutil-55`、`swscale-4`、`LIBEAY32`（序号）、`libcef`、Qt5 全家桶、`MSVCR120`。

`crypto_box_keypair` + `crypto_box_beforenm` + `crypto_stream_chacha20_xor` 三者同时出现，等于明写"X25519 生成密钥对 → 与设备公钥做 key exchange → ChaCha20 流加密"。

### 8.4 登录与云端接口（字符串证据）

CEF 负责登录、Qt 负责界面与网络，URL 与符号都能在字符串表里直接读到（ASCII + UTF-16LE 双向提取）：

- 登录：`https://account.xiaomi.com/pass/serviceLogin`、`https://account.xiaomi.com/pass/logout`、`//account.xiaomi.com/pass/auth/security/home`、`http://api.account.xiaomi.com/pass/usersCard`，以及服务端返回的 `&&&START&&&` 前缀
- 登录符号：`ServiceLogin::login` / `ServiceLogin::getLocation` / `ServiceLogin::getServiceToken` / `ServiceLogin::handleSslErrors`、`MiAccount::loginByWeb` / `loginByCache` / `logout` / `auto_login`
- 云 API：`https://api.io.mi.com/app`、`/home/device_list`、`/home/rpc`、`get_prop`、appId 字符串 `xiaomiio`
- 取流凭证：`/device/devicepass`，请求/响应字段 `toSignAppData`、`signForAppData`、`p2p_id`、`p2p_dev_public_key`
- 签名：`ssecurity`、`serviceToken`、`nonce`、`nonce=%1&%2`，以及 C++ 类名 `RC4DropCoder`（`.?AVRC4DropCoder@@`）
- 业务封装：`MiotApi::getDeviceList` / `getRoomList` / `getProperties` / `getPropertiesSync` / `setProperty` / `getDevicePassSync`（配套 `onGet*Finished` 槽）
- 更新与统计：`http://update.miui.com/updates/mi-updateV6.php?v=0.0.1&c=4.0&d=MiCamera&b=X`、`http://data.mistat.xiaomi.com/mistats/v2`
- 机型特判：字面量 `chuangmi.camera.ipc009`
- 编译环境：`C:\Users\zhaoquanguo\work\git.n.xiaomi.com\micamera\bin\MiCamera.pdb`，`CompanyName = Xiaomi.Inc`

也就是说：**登录、签名、云接口与 MenuBarMijia 的 `MiCloudClient` 是同一套**（`serviceLogin → location → serviceToken` + RC4-drop 签名 + `api.io.mi.com/app`），差别只是它用的还是老的 `home/device_list` / `home/rpc` / `get_prop`（老 miio 云），而不是 `miotspec/*`。

### 8.5 直播链路（拼出来的完整调用序）

1. 云侧取凭证：`POST /app/device/devicepass`，body `{"did": …, "toSignAppData": <X25519 客户端公钥>}` → `p2p_id`（TUTK UID）、`password`、`p2p_dev_public_key`、`signForAppData`
2. 建 P2P：`IOTC_Initialize2()` → `IOTC_Connect_ByUID_Parallel(p2p_id)` → `IOTC_Get_SessionID` → `IOTC_Session_Check` → `IOTC_Session_Get_Free_Channel`
3. 起流：`avInitialize()` → `avClientStart2()` → 循环 `avRecvFrameData2()`（视频）/ `avRecvAudioData()`（音频）→ FFmpeg 解码 → Qt5Multimedia 播放
4. 控制：`avSendIOCtrl()` / `avRecvIOCtrl()`，事件分发在 `CameraController::onIoctrlEvent`；清晰度切换走 `CameraController::setVideoQuality` → `MiCameraClient::setVideoQuality`（信号名 `setVideoQuality_s`）；音频开关 `camera %s: audio on/off`
5. 附加数据通道：`RDT_Initialize/RDT_Create`，线程 `RDTUpdatethread::handleStarted`，入口 `CameraController::startRDT` / `MiCameraClient::handleStartRDT`
6. 应用层加密：X25519 协商 + ChaCha20 加密载荷（对应 libsodium 的 4 个导入），密钥来源就是第 1 步的公钥交换

### 8.6 三方对照：官方客户端 / go2rtc / miloco

| 层 | 官方 `MiCamera.exe` 1.0.12060 | `AlexxIT/go2rtc`（`internal/xiaomi` + `pkg/tutk` + `pkg/xiaomi/miss`） | `XiaoMi/xiaomi-miloco`（`libmiot_camera_lite`） |
| --- | --- | --- | --- |
| 登录 | `account.xiaomi.com/pass/serviceLogin`（CEF） | 同样走账号密码/验证码 OAuth（`internal/xiaomi`） | 未公开（闭源） |
| 取凭证 | `POST /app/device/devicepass` | `getLegacyURL()` 打同一接口（`xiaomi.go:110-149`）；MISS 走 `/v2/device/miss_get_vendor`（`:152-196`） | 未公开 |
| P2P 传输 | TUTK IOTC by UID（`IOTC_Connect_ByUID_Parallel`） | 自研 TUTK：`pkg/tutk`（`Session16`/`Session25`、私有 cipher suite `0xCCAC` = ChaCha20-Poly1305、PSK = `SHA256(ENR)`）；另支持 CS2 | PPCS（文档原文） |
| 媒体 | AVAPIs 帧回调 + FFmpeg 软解 | 自解包 → 转 RTSP/HLS/WebRTC/MJPEG | 裸帧 + 自带解码，转 H.264 给浏览器 |
| 控制 | AVAPIs IOCtrl（清晰度、音频开关…） | `SendIOCtrl`/`RecvIOCtrl`（`pkg/tutk/conn.go:112-131`） | 无 PTZ、无对讲 |
| 载荷加密 | libsodium X25519 + ChaCha20 | MISS `crypto.Encode(data, key)`；TUTK 侧 DTLS | 未公开 |
| 遗留物 | — | `pkg/tutk/crypto.go` 里留着 TUTK 的混淆常量 `"Charlie is the designer of P2P!!"` | — |

**所以：go2rtc 已经把这套协议逆完了，而且逆得比官方客户端暴露的还多**（官方只用了 IOTC/AVAPIs 的一小部分导出；go2rtc 连 DTLS 都重写了）。再逆 `IMICamera` 在协议层不会得到新东西。

### 8.7 对 MenuBarMijia 的判断

1. **没有"更省事"的路径。** 整个客户端里不存在 RTSP/HLS/明文 HTTP 视频端点：所有视频帧都是 `avRecvFrameData2` 的回调，`avcodec-57` 只做本地解码。
2. **依赖不可分发。** TUTK 的 `IOTCAPIs/AVAPIs/RDTAPIs/P2PTunnelAPIs` 是商业 SDK 二进制（无源码、无授权），FFmpeg 与 libsodium 体积合计 >30 MB，`libcef` 46.7 MB。这与"零第三方 Swift 依赖"的仓库原则正相反。
3. **纯 Swift 复刻的成本**：等于把 go2rtc 的 `pkg/tutk`（会话握手、IOCtrl、帧封装、DTLS/0xCCAC）搬到 Swift，再自己实现 ChaCha20（CryptoKit 只给 Curve25519，没有 ChaCha20），保守估计 2–3k 行密码学+P2P 代码，且必须靠真机反复试错。收益与 §5 Tier 3 的判断一致：**不做**。
4. **新增一条否定结论**：连"官方 PC 客户端"这条理由也不成立 —— 它自己就是"闭源 SDK + 私有加密"的集合体，没有可复用的合规接口。

### 8.8 复现步骤

```bash
mkdir -p "$TEMP/imicamera_re" && cd "$TEMP/imicamera_re"
curl -sIL https://portal.cdn.imilab.com/static/upload/20220909/IMICamera_setup.1.7.9.2.exe   # 404
curl -o MiCamera-1.0.12060.2.exe \
  http://miuirom.xiaomi.com/rom/u491047765/1.0.12060.2/MiCamera-1.0.12060.2.exe            # 51,872,712 B
curl -sL -o innoextract.zip \
  https://github.com/dscharrer/innoextract/releases/download/1.9/innoextract-1.9-windows.zip && tar -xf innoextract.zip
cmd.exe /c "innoextract.exe -l MiCamera-1.0.12060.2.exe"                                    # 文件清单
cmd.exe /c "innoextract.exe -e -d extract MiCamera-1.0.12060.2.exe"                          # 解包
# 之后：PE 导入表用自写解析（python struct），字符串用 ASCII + UTF-16LE 双向正则
```

分析完成后临时目录 `$TEMP/imicamera_re`（约 155 MB 解包产物 + 52 MB 安装包）已全部删除，仓库内未落任何二进制。

---

## 附记（2026-10-31，Windows 端回归修复与已知限制）

- **卡首帧根因（实测）**：摄像机的单 P2P 会话承载过视频后需要一分多钟才能被它自己回收；期间重新协商只拿得到首帧（0–14 fps，健康基线 326 fps）。Windows 端据此把「关闭小窗」改为隐藏保温、120 秒无人观看才拆除并向摄像机下发 `stop-stream`，协商任务带代次检查、过期启动会被回收。诊断脚本在维护者本机 `.scratch/camera-diag/`（不入库）。
- **已知限制**：云 HLS（`camera-stream-for-google-home.start-hls-stream`）的四个类型化入参无一手来源，两端都只尝试空入参与 `[1]`，失败即回落 P2P——该路径是实验性兜底，不是承诺能力；`stop-stream` 下发的线级断言与 macOS 端会话生命周期测试暂未覆盖。
