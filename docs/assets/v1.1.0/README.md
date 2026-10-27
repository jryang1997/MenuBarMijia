# 1.1.0 README 素材来源

采集日期为 2026-10-27。新版素材使用实际 macOS App 界面，不用生成图片模拟 UI。两组 GIF 由按操作顺序保存的真实截图组成，停留时间为便于阅读而设置，不用于展示响应耗时。

| 文件 | 来源与内容 |
| --- | --- |
| `panel.png` | 本轮运行中的 1.1.0 App，霜白皮肤、标准高度、离线演示家庭。 |
| `search.png` | 同一 App 输入 `sftd`，实际匹配「书房台灯」。 |
| `search-control-undo.gif` | 本轮六个连续步骤：主面板、搜索、回车开灯、输入「关闭所有灯」、执行、点击撤销。开启数实测为 4 → 5 → 3 → 5，所有设备均为虚拟设备。 |
| `automation.png` | 本轮设置窗口的真实截图，仅裁剪自动化区域。规则为空，URL 跳过确认关闭。 |
| `automation-setup.gif` | 本轮五个连续步骤截图：原始配置、动作菜单、指定设备列表、滚动、勾选书房台灯。停在添加规则前，没有保存临时规则。 |
| `shortcuts.png` | 复用当日 [Mac 实机验收](../../qa/mac-acceptance-2026-10-27.md) 的 [Shortcuts 原始截图](../../qa/evidence/pr65/shortcuts-discovery.png)，裁剪右侧四动作列表。 |

主面板、搜索和自动化均为演示家庭，读数与设备状态为虚拟数据。没有在本轮操作真实硬件，也没有采集账号、登录二维码或密钥。采集后恢复经典皮肤、最大高度与米家云端直连。

功能文案核对自 `CHANGELOG.md` 和当前源码：`MenuBarPanelController.swift`、`PanelSearch` 相关实现、`AppIntents.swift`、`AutomationSettingsSection.swift`、`AutomationEngine.swift`、`EnergySettingsSection.swift`。没有宣称竞品独家或未经复现的性能提升。
