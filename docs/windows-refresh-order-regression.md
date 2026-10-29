# Windows 轮询排序回归，#81

## 1.1.2 为什么没有修完

1.1.2 修复了相同快照的重绘、动态值更新与交互保护，但回归测试的云端数据只有一台灯，不能检测列表顺序变化。

Windows 面板每约 6 秒拉取米家设备列表。此前 `refreshXiaomiDevices` 将 `home.devices` 直接赋给 `this.devices`；设备卡片沿用该数组顺序，房间标签取其房间名的首次出现顺序，环境读数也沿用合成输入顺序。相同设备集合的排列变化会改变结构指纹，引发重绘和位置跳动。

## 可执行复现

在 `windows/` 运行：

```sh
npx tsx --test --test-name-pattern="permutes" tests/ui.test.ts
```

测试通过真实面板计时器、米家响应解析和设备合成路径，在模拟的原生 HTTP 边界反转设备、房间返回顺序。修复前输出：

```text
AssertionError: cloud response order moved device tiles
actual:   [ 'second-light', 'fixture-light' ]
expected: [ 'fixture-light', 'second-light' ]
```

本机安装的 1.1.2 使用已有登录态被动读取，约 50 秒采样 25 次，面板共 27 台设备，观察到 8 种设备排列、8 种房间标签排列、2 种温湿度排列。探针只强制页面处于可见/聚焦的轮询条件，不发送设备控制指令。记录未包含登录凭据或设备标识。

## 修复与回归边界

- 按上一轮设备 ID 顺序接纳最新状态，已不存在的设备移除，新设备追加。
- 环境读数按稳定设备顺序排列；家庭选项保留已有顺序。
- 用户拖拽顺序继续在展示层优先生效，稳定的基础顺序写回已有设备缓存。
- UI 回归覆盖交替乱序并同时更新亮度、温度，检查磁贴、房间标签、环境读数位置与 DOM 连续性；另测设备增删、部分自定义排序和启动缓存。
- Windows 本机没有 Swift。`bash scripts/check.sh` 的密钥与机械检查通过，随后因 `swift: command not found` 停止；Swift 和 macOS 检查由同提交的 CI 执行，合并前必须确认结果。

本次不改变米家协议、设备指令、登录凭据或 macOS 行为。
