# MenuMijia 改进方案 v1（已冻结 2026-10-17）

> 冻结：范围和顺序不再改动。要改，另开 v2。所有改动在 `plan-v1` 分支，小步提交。

## 执行顺序
0. 名字统一：README / App / 文档统一为 MenuMijia；评估 "Mijia" 商标风险。
1. 安装版前置：Developer ID 签名 + 公证、DMG、自动更新（Sparkle）、首次引导（麦克风/扫码/Key）、看得懂的错误提示。
2. 指令能力：风扇档位、扫地机启停/回充、音量、窗帘/门锁识别；定时/延时；多轮上下文（"再暗一点""撤销"）；条件（后置）。
3. 速度稳定：6 秒轮询 → 局域网直连/推送；简单指令本机直接执行，不依赖大模型（10 秒超时兜底）。
4. 隐私：习惯记忆可查看/删除/关闭；语音"仅本机识别"开关；写明哪些数据发给大模型。
5. 入口：Siri / 快捷指令（App Intents）、小组件 / 控制中心控件、自定义热键。
6. 跨端：先抽出共享核心（理解指令 + 决策），再做 Windows；安卓一键说话先做简版，习惯同步后定。
7. 工程：拆分 HomeStore.swift（1674 行），补指令和设备控制测试。

## 现状依据（代码核对）
- 凭证：API Key 与米家会话都在钥匙串（ThisDeviceOnly）
- 习惯：UserDefaults，作为 user_habits 发给大模型
- 云端：MiCloudProvider 轮询 6s；大模型请求超时 10s
- 语音：SFSpeechRecognizer zh-CN，未设 requiresOnDeviceRecognition
- 打包：build_app.sh 仅 ad-hoc 签名；已有 SMAppService 开机自启
