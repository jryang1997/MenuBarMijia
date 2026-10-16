# 0002. 双后端 HomeProvider 架构与米家云端直连

MenuBarMijia 通过统一的 `HomeProvider` 协议（事件流 `SynthesizedHome` 与领域指令 `DeviceCommand`）隔离底层数据源，同时支持局域网 `HAWebSocketProvider` 与直连小米云的 `MiCloudProvider`（`HomeBackend`）。针对没有群晖 NAS 或 Docker 环境的普通用户，`MiCloudProvider` 采用小米账号扫码登录获取 `MiSession`，拉取 `miot-spec.org` 的设备规格（`MiotSpec`）并在本地磁盘缓存，通过 `MiotSynthesizer` 与 `MiotCommandMapper` 将 `siid/piid/aiid` 属性与动作无损映射为同一套 `SmartDevice` 模型与控制指令。相比 Home Assistant WebSocket 的毫秒级事件推送，米家云端直连受限于官方 HTTP RC4 接口采用周期轮询加写后即时追询（乐观锁掩盖往返延迟），但彻底消除了自建网关的准入门槛，且上层视图、快捷动作与 AI 自然语言指令无需感知后端差异。
