# 0003. 核心库保持可在 Linux 上编译

`MijiaCore` 只依赖 Foundation，外加少量苹果专属模块：`os.Logger`、`Security`（钥匙串）、`CryptoKit`。`scripts/linux-check/` 用很薄的替身（Logger 打印、内存钥匙串、swift-crypto）替换这几样，就能在 Linux 上编译并跑完全部单元测试，业务代码一行不改。我们决定把这一点当作约束保留下来：新代码进 `MijiaCore` 时不要引入 AppKit、SwiftUI 或其他苹果专属框架，平台相关的东西放在 App 层或用协议隔开。这样做有两个好处：一是 CI 和没有 Mac 的贡献者也能验证核心逻辑；二是将来做 Windows/Linux 版时，设备合成、意图解析、习惯记忆可以直接复用，只需要重写界面和钥匙串这一层。代价是替身需要跟着这些模块的用法同步维护，CI 的 Linux 任务会在它们失效时报错。
