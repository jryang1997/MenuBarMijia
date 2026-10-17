// swift-tools-version: 6.0
// Linux 下验证 MijiaCore 的临时包：用 run.sh 调用，不参与 macOS 构建。
import PackageDescription
let package = Package(
  name: "LinuxCheck",
  dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")],
  targets: [
    .target(name: "ThreadingShim", path: "Shims/ThreadingShim"),
    .target(name: "os", dependencies: ["ThreadingShim"], path: "Shims/os"),
    .target(name: "Security", path: "Shims/Security"),
    .target(name: "CryptoKit", dependencies: [.product(name: "Crypto", package: "swift-crypto")], path: "Shims/CryptoKit"),
    .target(name: "MijiaCore", dependencies: ["os", "Security", "CryptoKit"], path: ".work/MijiaCore", swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(name: "MijiaCoreTests", dependencies: ["MijiaCore"], path: ".work/MijiaCoreTests", swiftSettings: [.swiftLanguageMode(.v6)])
  ])
