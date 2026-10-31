/**
 * Text catalog and language for the Windows control center (#52).
 *
 * Every user-visible string goes through `t("中文")`. The Chinese text is the key *and* the
 * Simplified Chinese value, English lives beside it in `CATALOG`, so a call site never carries two
 * copies of the same sentence and a missing translation is a test failure rather than a silent
 * Chinese leak. This mirrors the macOS `L10n.tr(zh, en)` inline catalog.
 *
 * `{name}` placeholders are filled by name, so a translation may reorder them.
 */

export type AppLanguage = "zh-Hans" | "en";
export type LanguagePreference = "system" | AppLanguage;

/** Chinese key → [Simplified Chinese, English]. */
const CATALOG: Readonly<Record<string, readonly [string, string]>> = {
  // Chrome
  "切换家庭": ["切换家庭", "Switch home"],
  "演示预览": ["演示预览", "Demo preview"],
  "Miot 直连": ["Miot 直连", "Miot direct"],
  "拖动卡片排序 · 点角标改大小": ["拖动卡片排序 · 点角标改大小", "Drag to reorder · tap the badge to resize"],
  "语音控制": ["语音控制", "Voice control"],
  "AI 自然语言指令栏": ["AI 自然语言指令栏", "AI command bar"],
  "AI 自然语言指令栏 (/)": ["AI 自然语言指令栏 (/)", "AI command bar (/)"],
  "完成": ["完成", "Done"],
  "完成布局编辑": ["完成布局编辑", "Finish layout editing"],
  "全关": ["全关", "All off"],
  "全关·{room}": ["全关·{room}", "All off · {room}"],
  "全关，关闭 {count} 台设备，按住 0.6 秒确认": ["全关，关闭 {count} 台设备，按住 0.6 秒确认", "All off: switch off {count} devices, hold 0.6 s to confirm"],
  "按住 0.6 秒关闭这 {count} 台（插座、扫地机默认不参与，可在设置里调整）": ["按住 0.6 秒关闭这 {count} 台（插座、扫地机默认不参与，可在设置里调整）", "Hold 0.6 s to switch off these {count} (plugs and vacuums opt out by default; adjustable in Settings)"],
  "按住 0.6 秒关闭这 {count} 台（插座、扫地机默认不参与）": ["按住 0.6 秒关闭这 {count} 台（插座、扫地机默认不参与）", "Hold 0.6 s to switch off these {count} (plugs and vacuums opt out by default)"],
  "收起面板到右下角托盘 (Esc)": ["收起面板到右下角托盘 (Esc)", "Hide to the tray (Esc)"],
  "收起面板": ["收起面板", "Hide panel"],
  "切换为单列详情视图": ["切换为单列详情视图", "Switch to single-column detail view"],
  "切换为双列控制中心磁贴": ["切换为双列控制中心磁贴", "Switch to two-column tile view"],
  "立即同步最新设备状态": ["立即同步最新设备状态", "Sync device state now"],
  "连接设置与 AI 决策配置": ["连接设置与 AI 决策配置", "Connection and AI settings"],
  "打开设置": ["打开设置", "Open settings"],
  "完全退出 MenuBarMijia": ["完全退出 MenuBarMijia", "Quit MenuBarMijia"],
  "退出": ["退出", "Quit"],
  "扫码直连": ["扫码直连", "Scan to connect"],
  "用手机米家 App 扫码直连真实设备": ["用手机米家 App 扫码直连真实设备", "Scan with the Mi Home app to connect real devices"],
  "切换卡片大小": ["切换卡片大小", "Change card size"],
  "点击直接切换开关": ["点击直接切换开关", "Tap to toggle"],
  "点击展开精细调节": ["点击展开精细调节", "Tap to expand fine controls"],
  "点击切换开关": ["点击切换开关", "Tap to toggle"],
  "展开详细控制": ["展开详细控制", "Show detailed controls"],
  "收起详细控制": ["收起详细控制", "Hide detailed controls"],
  "收起": ["收起", "Collapse"],
  "展开": ["展开", "Expand"],
  "{name} 开关": ["{name} 开关", "{name} switch"],
  "{name} 详细控制": ["{name} 详细控制", "{name} detailed controls"],
  "更多设备": ["更多设备", "More devices"],
  "其他": ["其他", "Other"],
  "全部": ["全部", "All"],
  "全部家庭": ["全部家庭", "All homes"],
  "我的米家": ["我的米家", "My Mi Home"],
  "关闭引导": ["关闭引导", "Close guide"],
  "返回控制中心": ["返回控制中心", "Back to control center"],
  "切換家庭": ["切換家庭", "Switch home"],

  // Status summaries
  "{count} 台开启中 · 共 {online} 台在线": ["{count} 台开启中 · 共 {online} 台在线", "{count} on · {online} online"],
  "全屋待机 · {online} 台实时在线": ["全屋待机 · {online} 台实时在线", "All idle · {online} online"],
  "演示预览 · 点击下方「扫码直连」同步你的真机": ["演示预览 · 点击下方「扫码直连」同步你的真机", "Demo preview · use “Scan to connect” to sync your devices"],
  "正在从小米云端同步真实设备...": ["正在从小米云端同步真实设备...", "Syncing devices from Xiaomi Cloud…"],
  "米家账号 {user} · {count} 台设备": ["米家账号 {user} · {count} 台设备", "Mi account {user} · {count} devices"],
  "演示模式 · 未连接米家云": ["演示模式 · 未连接米家云", "Demo mode · Mi Cloud not connected"],
  "已同步 {count} 台真实米家设备": ["已同步 {count} 台真实米家设备", "Synced {count} devices"],
  "当前小米账号下暂未发现米家设备": ["当前小米账号下暂未发现米家设备", "No Mi Home devices in this account"],
  "米家云同步失败：{message}": ["米家云同步失败：{message}", "Mi Cloud sync failed: {message}"],
  "米家云直连": ["米家云直连", "Mi Cloud direct"],
  "连接异常": ["连接异常", "Connection error"],

  // Device states
  "已关闭": ["已关闭", "Off"],
  "已开启": ["已开启", "On"],
  "已断电": ["已断电", "Power cut"],
  "在线": ["在线", "Online"],
  "离线": ["离线", "Offline"],
  "运行中": ["运行中", "Running"],
  "待命": ["待命", "Standby"],
  "清扫中": ["清扫中", "Cleaning"],
  "已暂停": ["已暂停", "Paused"],
  "回充中": ["回充中", "Returning"],
  "充电座待命": ["充电座待命", "Docked"],
  "供电中": ["供电中", "Powering"],
  "供电中 · {watts}W": ["供电中 · {watts}W", "Powering · {watts}W"],
  "摇头": ["摇头", "Oscillating"],
  "摇头 开": ["摇头 开", "Oscillation on"],
  "摇头 关": ["摇头 关", "Oscillation off"],
  "制冷": ["制冷", "Cool"],
  "制热": ["制热", "Heat"],
  "除湿": ["除湿", "Dry"],
  "送风": ["送风", "Fan only"],
  "自动": ["自动", "Auto"],
  "已关闭 · 室温 {temp}": ["已关闭 · 室温 {temp}", "Off · Room {temp}"],
  "室温 {temp}": ["室温 {temp}", "Room {temp}"],
  "目标温度": ["目标温度", "Target temperature"],
  "目标温度 {temp}": ["目标温度 {temp}", "Target temperature {temp}"],
  "目标温度进度": ["目标温度进度", "Target temperature progress"],
  "降低温度": ["降低温度", "Lower temperature"],
  "升高温度": ["升高温度", "Raise temperature"],
  "降低目标温度": ["降低目标温度", "Lower target temperature"],
  "升高目标温度": ["升高目标温度", "Raise target temperature"],
  "亮度": ["亮度", "Brightness"],
  "亮度 {percent}%": ["亮度 {percent}%", "Brightness {percent}%"],
  "色温": ["色温", "Color temp"],
  "风速": ["风速", "Fan speed"],
  "关闭空调": ["关闭空调", "Turn off"],
  "打开空调": ["打开空调", "Turn on"],
  "关闭 {name}": ["关闭 {name}", "Turn off {name}"],
  "打开 {name}": ["打开 {name}", "Turn on {name}"],
  "{name}，温度 {temp}{humidity}": ["{name}，温度 {temp}{humidity}", "{name}, temperature {temp}{humidity}"],
  "，湿度 {humidity}%": ["，湿度 {humidity}%", ", humidity {humidity}%"],
  "，离线": ["，离线", ", offline"],

  // Quick actions
  "全开主灯": ["全开主灯", "All main lights on"],
  "睡眠关灯": ["睡眠关灯", "Lights off for sleep"],
  "{temp} 制冷": ["{temp} 制冷", "{temp} cool"],
  "调亮灯光": ["调亮灯光", "Brighten lights"],
  "打开所有灯": ["打开所有灯", "Turn on all lights"],
  "关闭所有灯": ["关闭所有灯", "Turn off all lights"],
  "再亮一点": ["再亮一点", "A bit brighter"],
  "空调调到25度": ["空调调到25度", "Set the AC to 25 degrees"],

  // Reply banner sources
  "一键全关": ["一键全关", "All off"],
  "0ms 本地直达": ["0ms 本地直达", "0 ms local"],
  "习惯记忆 0ms": ["习惯记忆 0ms", "Learned habit, 0 ms"],
  "定时任务": ["定时任务", "Scheduled"],
  "地址不安全": ["地址不安全", "Insecure address"],
  "需要 API Key": ["需要 API Key", "API key needed"],
  "需要确认": ["需要确认", "Confirmation needed"],
  "出错提示": ["出错提示", "Error"],
  "控制失败": ["控制失败", "Control failed"],
  "撤销提示": ["撤销提示", "Undo"],
  "已恢复": ["已恢复", "Restored"],
  "实时控制": ["实时控制", "Live control"],
  "提示": ["提示", "Notice"],
  "已取消": ["已取消", "Cancelled"],
  "已确认": ["已确认", "Confirmed"],
  "语音提示": ["语音提示", "Voice"],
  "扫码成功": ["扫码成功", "Signed in"],
  "检查更新": ["检查更新", "Update check"],
  "已执行 {ok} 项，{failed} 项失败。{message}": ["已执行 {ok} 项，{failed} 项失败。{message}", "Ran {ok}, {failed} failed. {message}"],
  "撤销未完成，{count} 项待恢复。{message}": ["撤销未完成，{count} 项待恢复。{message}", "Undo incomplete, {count} to restore. {message}"],
  "已撤销：{summary}": ["已撤销：{summary}", "Undone: {summary}"],
  "已关闭 {count} 台开启中的设备": ["已关闭 {count} 台开启中的设备", "Switched off {count} devices"],
  "设备未响应": ["设备未响应", "Device did not respond"],
  "设备未响应或离线": ["设备未响应或离线", "Device did not respond or is offline"],
  "设备列表已更新，请重新执行": ["设备列表已更新，请重新执行", "The device list changed; please run the command again"],
  "没有可撤销的操作（仅支持 10 分钟内的操作撤销）": ["没有可撤销的操作（仅支持 10 分钟内的操作撤销）", "Nothing to undo (undo covers the last 10 minutes)"],
  "无法找到指令对应的设备": ["无法找到指令对应的设备", "No matching device for that command"],
  "没有发送。「打开书房灯」这类简单指令不用联网。": ["没有发送。「打开书房灯」这类简单指令不用联网。", "Not sent — simple commands like “turn on the study light” never need the network."],
  "未命中本地规则。请在设置中填写 AI 服务的 API Key（支持 OpenRouter Jev、原生 Jev、DeepSeek 等）。": ["未命中本地规则。请在设置中填写 AI 服务的 API Key（支持 OpenRouter Jev、原生 Jev、DeepSeek 等）。", "No local rule matched. Add an API key for the AI service in Settings (OpenRouter Jev, native Jev, DeepSeek, …)."],
  "这句话本机没听懂，要交给云端 AI（{endpoint}）处理吗？会发送：这句话、设备名称/房间/状态。只问这一次，可在设置里撤销。": ["这句话本机没听懂，要交给云端 AI（{endpoint}）处理吗？会发送：这句话、设备名称/房间/状态。只问这一次，可在设置里撤销。", "Couldn't parse that offline. Send it to the cloud AI ({endpoint})? It receives this sentence plus device names, rooms and states. Asked once; revocable in Settings."],
  "已取消 {count} 项定时指令": ["已取消 {count} 项定时指令", "Cancelled {count} scheduled commands"],
  "当前没有待执行的定时指令": ["当前没有待执行的定时指令", "No scheduled commands pending"],
  "已设定 {delay}后执行「{command}」": ["已设定 {delay}后执行「{command}」", "Scheduled “{command}” in {delay}"],
  "{delay}后：{command}": ["{delay}后：{command}", "In {delay}: {command}"],
  "已错过定时：{command}（电脑睡眠时到点，没有自动执行）": ["已错过定时：{command}（电脑睡眠时到点，没有自动执行）", "Missed schedule: {command} (came due while the PC slept; not run)"],
  "立即执行": ["立即执行", "Run now"],
  "忽略": ["忽略", "Dismiss"],
  "{command} · 剩余 {remaining}": ["{command} · 剩余 {remaining}", "{command} · {remaining} left"],
  "取消": ["取消", "Cancel"],
  "撤销": ["撤销", "Undo"],
  "允许并发送": ["允许并发送", "Allow and send"],
  "不用了": ["不用了", "Not now"],
  "说一句：我困了 / 调低两度 / 10分钟后关灯 / 撤销...": ["说一句：我困了 / 调低两度 / 10分钟后关灯 / 撤销...", "Say: I'm sleepy / two degrees cooler / lights off in 10 minutes / undo…"],
  "自然语言指令": ["自然语言指令", "Natural-language command"],
  "执行指令": ["执行指令", "Run command"],
  "执行指令 (Enter)": ["执行指令 (Enter)", "Run command (Enter)"],

  // Durations
  "{minutes}分{seconds}秒": ["{minutes}分{seconds}秒", "{minutes}m {seconds}s"],
  "{minutes}分钟": ["{minutes}分钟", "{minutes}m"],
  "{seconds}秒": ["{seconds}秒", "{seconds}s"],

  // Cloud sign-in
  "点击下方按钮获取安全二维码，用手机「米家 App → 扫一扫」即可同步真实全屋设备。": ["点击下方按钮获取安全二维码，用手机「米家 App → 扫一扫」即可同步真实全屋设备。", "Get a secure QR code below, then scan it with “Mi Home → Scan” to sync your devices."],
  "正在获取小米安全登录二维码...": ["正在获取小米安全登录二维码...", "Requesting a Xiaomi sign-in QR code…"],
  "正在等待手机米家扫码确认...": ["正在等待手机米家扫码确认...", "Waiting for confirmation in Mi Home…"],
  "获取米家登录二维码": ["获取米家登录二维码", "Get Mi Home QR code"],
  "请打开手机「米家 App → 我的 → 右上角扫一扫」确认登录": ["请打开手机「米家 App → 我的 → 右上角扫一扫」确认登录", "Open “Mi Home → Profile → Scan” on your phone to confirm"],
  "已连接小米账号 {user}": ["已连接小米账号 {user}", "Connected to Mi account {user}"],
  "已登录小米账号 {user}，正在拉取真实设备...": ["已登录小米账号 {user}，正在拉取真实设备...", "Signed in as {user}, loading devices…"],
  "扫码未完成：{message}": ["扫码未完成：{message}", "Scan not completed: {message}"],
  "二维码已过期，请重新获取": ["二维码已过期，请重新获取", "The QR code expired; request a new one"],
  "切换/重新扫码 (已登录 {user})": ["切换/重新扫码 (已登录 {user})", "Switch / rescan (signed in as {user})"],
  "请先扫码登录米家": ["请先扫码登录米家", "Sign in to Mi Home first"],
  "Windows 端暂不支持 Home Assistant 连接": ["Windows 端暂不支持 Home Assistant 连接", "Home Assistant isn’t supported on Windows yet"],
  "当前系统环境不支持离线语音识别，请直接输入文字指令。": ["当前系统环境不支持离线语音识别，请直接输入文字指令。", "On-device speech recognition isn’t available here; please type the command."],

  // Empty states
  "正在同步你的真实米家设备…": ["正在同步你的真实米家设备…", "Syncing your devices…"],
  "正在从小米云端拉取房间、MIoT 规格与实时状态": ["正在从小米云端拉取房间、MIoT 规格与实时状态", "Fetching rooms, MIoT specs and live state from Xiaomi Cloud"],
  "尚未同步到米家设备": ["尚未同步到米家设备", "No Mi Home devices synced yet"],
  "当前地区（{region}）没有设备，可尝试切换地区": ["当前地区（{region}）没有设备，可尝试切换地区", "No devices in this region ({region}); try switching regions"],
  "重新同步设备": ["重新同步设备", "Sync devices again"],
  "切换账号 / 设置": ["切换账号 / 设置", "Switch account / Settings"],

  // Layout menus
  "重命名": ["重命名", "Rename"],
  "上移分组": ["上移分组", "Move group up"],
  "下移分组": ["下移分组", "Move group down"],
  "删除分组": ["删除分组", "Delete group"],
  "卡片大小（本页）": ["卡片大小（本页）", "Card size (this page)"],
  "移到分组": ["移到分组", "Move to group"],
  "不分组": ["不分组", "No group"],
  "＋ 新建": ["＋ 新建", "＋ New"],
  "重命名…": ["重命名…", "Rename…"],
  "编辑布局": ["编辑布局", "Edit layout"],
  "新建分组": ["新建分组", "New group"],
  "例如：灯光、电器、环境": ["例如：灯光、电器、环境", "e.g. Lights, Appliances, Climate"],
  "重命名分组": ["重命名分组", "Rename group"],
  "重命名设备": ["重命名设备", "Rename device"],
  "只在本 App 显示，不会修改米家里的名字": ["只在本 App 显示，不会修改米家里的名字", "Shown in this app only; the Mi Home name is unchanged"],
  "恢复原名": ["恢复原名", "Restore name"],
  "保存": ["保存", "Save"],
  "删除": ["删除", "Delete"],

  // Onboarding
  "首次设置": ["首次设置", "First-time setup"],
  "MenuBarMijia 控制中心": ["MenuBarMijia 控制中心", "MenuBarMijia control center"],
  "扫码直连你的真实米家设备": ["扫码直连你的真实米家设备", "Scan to connect your real devices"],
  "手机打开「米家 App → 扫一扫」即可直接同步全屋真实设备；常驻 Windows 右下角系统托盘，点击图标或按 Alt+M 随时弹出，点击外部自动收起。": ["手机打开「米家 App → 扫一扫」即可直接同步全屋真实设备；常驻 Windows 右下角系统托盘，点击图标或按 Alt+M 随时弹出，点击外部自动收起。", "Open “Mi Home → Scan” on your phone to sync your devices. The panel lives in the Windows tray: click the icon or press Alt+M to open it, and it hides when you click outside."],
  "云端服务器地区": ["云端服务器地区", "Cloud region"],
  "欧洲、印度、俄罗斯、新加坡、美区的米家账号请先选择对应地区，再扫码登录。": ["欧洲、印度、俄罗斯、新加坡、美区的米家账号请先选择对应地区，再扫码登录。", "For Europe, India, Russia, Singapore and US accounts, pick the matching region before scanning."],
  "OpenRouter API Key（可选，用于 Jev SystemOne 模糊意图决策）": ["OpenRouter API Key（可选，用于 Jev SystemOne 模糊意图决策）", "OpenRouter API key (optional, for Jev SystemOne intent decisions)"],
  "先看演示预览": ["先看演示预览", "Preview the demo"],
  "进入控制中心": ["进入控制中心", "Open the control center"],

  // Settings sheet
  "偏好设置": ["偏好设置", "Preferences"],
  "偏好设置与米家连接": ["偏好设置与米家连接", "Preferences and Mi Home connection"],
  "面板皮肤": ["面板皮肤", "Panel skin"],
  "经典以外的皮肤带有：卡片依次入场、在灯上左右拖动调亮度、按住「全关」0.6 秒确认。长按卡片可以拖动排序，右键卡片可以改大小、分组和重命名。": ["经典以外的皮肤带有：卡片依次入场、在灯上左右拖动调亮度、按住「全关」0.6 秒确认。长按卡片可以拖动排序，右键卡片可以改大小、分组和重命名。", "Skins other than Classic animate cards in, let you drag on a light to dim it, and require holding “All off” for 0.6 s. Long-press to reorder; right-click a card to resize, group or rename it."],
  "面板高度": ["面板高度", "Panel height"],
  "空调使用整行控制条": ["空调使用整行控制条", "Full-row air-conditioner bar"],
  "设备数据源": ["设备数据源", "Device source"],
  "米家云真实设备": ["米家云真实设备", "Real devices via Mi Cloud"],
  "演示设备预览": ["演示设备预览", "Demo devices"],
  "当前选择：{region}。切换后请重新扫码登录该地区的米家账号；已登录会话仍使用登录时的地区。": ["当前选择：{region}。切换后请重新扫码登录该地区的米家账号；已登录会话仍使用登录时的地区。", "Selected: {region}. After switching, sign in again with an account from that region; an existing session keeps the region it signed in with."],
  "AI 服务商预设（支持 OpenRouter Jev、原生 Jev、DeepSeek、千问、GLM 等）": ["AI 服务商预设（支持 OpenRouter Jev、原生 Jev、DeepSeek、千问、GLM 等）", "AI provider preset (OpenRouter Jev, native Jev, DeepSeek, Qwen, GLM, …)"],
  "AI 服务地址（支持 /v1/systemone 与 OpenAI 兼容 /v1/chat/completions）": ["AI 服务地址（支持 /v1/systemone 与 OpenAI 兼容 /v1/chat/completions）", "AI endpoint (supports /v1/systemone and OpenAI-compatible /v1/chat/completions)"],
  "决策模型（如 ~typesafe/jev-latest、jev-latest、deepseek-chat）": ["决策模型（如 ~typesafe/jev-latest、jev-latest、deepseek-chat）", "Decision model (e.g. ~typesafe/jev-latest, jev-latest, deepseek-chat)"],
  "API Key（本机安全保存）": ["API Key（本机安全保存）", "API key (stored securely on this PC)"],
  "已允许发送到：{endpoints}": ["已允许发送到：{endpoints}", "Allowed to send to: {endpoints}"],
  "撤销授权（下次发往云端前再问）": ["撤销授权（下次发往云端前再问）", "Revoke (ask again before the next cloud request)"],
  "「全关」包含哪些设备（插座、扫地机默认不包含）": ["「全关」包含哪些设备（插座、扫地机默认不包含）", "Devices included in “All off” (plugs and vacuums are excluded by default)"],
  "自动记住自然语言习惯（相同表达下次 0ms 本地直达）": ["自动记住自然语言习惯（相同表达下次 0ms 本地直达）", "Remember phrasing (the same words run locally in 0 ms next time)"],
  "软件更新": ["软件更新", "Software update"],
  "当前版本 v{version}": ["当前版本 v{version}", "Version v{version}"],
  "有新版本 v{version}，点击查看": ["有新版本 v{version}，点击查看", "v{version} is available — view it"],
  "发现新版本 v{version}": ["发现新版本 v{version}", "New version v{version}"],
  "更新 v{version}": ["更新 v{version}", "Update v{version}"],
  "立即更新": ["立即更新", "Update now"],
  "正在更新…": ["正在更新…", "Updating…"],
  "手动下载": ["手动下载", "Manual download"],
  "检查中…": ["检查中…", "Checking…"],
  "可直接下载并安装，无需打开浏览器": ["可直接下载并安装，无需打开浏览器", "Ready to download and install directly in the app"],
  "正在下载并校验 v{version} 安装包，完成后将自动启动安装…": ["正在下载并校验 v{version} 安装包，完成后将自动启动安装…", "Downloading and verifying v{version} installer; setup will start automatically…"],
  "下载或校验更新包失败，请重试或手动下载": ["下载或校验更新包失败，请重试或手动下载", "Failed to download or verify update package; please retry or download manually"],
  "立即检查": ["立即检查", "Check now"],
  "每天自动检查更新（关闭后不再请求 GitHub）": ["每天自动检查更新（关闭后不再请求 GitHub）", "Check for updates daily (off means no GitHub request)"],
  "退出 MenuBarMijia": ["退出 MenuBarMijia", "Quit MenuBarMijia"],
  "完成并保存": ["完成并保存", "Done and save"],
  "外观模式": ["外观模式", "Appearance"],
  "浅色": ["浅色", "Light"],
  "深色": ["深色", "Dark"],
  "切换浅色模式": ["切换浅色模式", "Switch to light mode"],
  "切换深色模式": ["切换深色模式", "Switch to dark mode"],
  "界面语言 / 语言": ["界面语言 / 语言", "Language"],
  "跟随系统": ["跟随系统", "System"],
  "简体中文": ["简体中文", "Simplified Chinese"],
  "English": ["English", "English"],
  "温度单位": ["温度单位", "Temperature unit"],
  "摄氏度 (°C)": ["摄氏度 (°C)", "Celsius (°C)"],
  "华氏度 (°F)": ["华氏度 (°F)", "Fahrenheit (°F)"],
  "检查更新失败，请稍后再试": ["检查更新失败，请稍后再试", "Update check failed; try again later"],
  "已是最新版本 v{version}": ["已是最新版本 v{version}", "v{version} is the latest version"],
  "启用全局呼出快捷键": ["启用全局呼出快捷键", "Enable global shortcut"],
  "呼出面板的快捷键": ["呼出面板的快捷键", "Show panel shortcut"],
  "按下组合…": ["按下组合…", "Press keys…"],
  "点击后按下新的组合；Esc 取消": ["点击后按下新的组合；Esc 取消", "Click, then press a new combination; Esc cancels"],
  "恢复 Alt+M": ["恢复 Alt+M", "Reset Alt+M"],
  "需要至少一个 Ctrl / Alt / Shift / Win，或单按 F1–F20。Esc 取消。": ["需要至少一个 Ctrl / Alt / Shift / Win，或单按 F1–F20。Esc 取消。", "Use at least one of Ctrl / Alt / Shift / Win, or a single F1–F20 key. Esc cancels."],
  "这个组合已被其他应用占用，换一个再试。": ["这个组合已被其他应用占用，换一个再试。", "Another app already owns this shortcut. Try a different combination."],
  "重试": ["重试", "Retry"],

  // Demo home, rooms and scenes
  "客厅吸顶灯": ["客厅吸顶灯", "Living room ceiling light"],
  "客厅立式空调": ["客厅立式空调", "Living room AC"],
  "书房台灯": ["书房台灯", "Study desk lamp"],
  "主卧直流风扇": ["主卧直流风扇", "Master bedroom fan"],
  "玄关智能插座": ["玄关智能插座", "Entryway plug"],
  "全屋扫拖机器人": ["全屋扫拖机器人", "Robot vacuum"],
  "客厅温湿度计": ["客厅温湿度计", "Living room thermo-hygrometer"],
  "客厅": ["客厅", "Living room"],
  "书房": ["书房", "Study"],
  "主卧": ["主卧", "Master bedroom"],
  "玄关": ["玄关", "Entryway"],
  "回家模式": ["回家模式", "Arrive home"],
  "专注模式": ["专注模式", "Focus"],
  "睡眠模式": ["睡眠模式", "Sleep"],
  "离家模式": ["离家模式", "Leave home"],
  "{name}，温度 {temp}": ["{name}，温度 {temp}", "{name}, temperature {temp}"],
  "· 剩余 {remaining}": ["· 剩余 {remaining}", "· {remaining} left"],
  "25°制冷": ["25°制冷", "25° cool"],

  // Reply templates for local/redo commands
  "开": ["开", "On"],
  "关": ["关", "Off"],
  "打开": ["打开", "Turned on"],
  "关闭": ["关闭", "Turned off"],
  "开启": ["开启", "Enabled"],
  "已将{name}设为 {temp}": ["已将{name}设为 {temp}", "Set {name} to {temp}"],
  "已将{name}设为 {speed}": ["已将{name}设为 {speed}", "Set {name} to {speed}"],
  "已将{name}亮度设为 {percent}%": ["已将{name}亮度设为 {percent}%", "Set {name} brightness to {percent}%"],
  "已将{name}色温设为 {kelvin}K": ["已将{name}色温设为 {kelvin}K", "Set {name} color temp to {kelvin}K"],
  "已将{name}风速设为 {speed}": ["已将{name}风速设为 {speed}", "Set {name} fan speed to {speed}"],
  "已切换{name}灯光模式": ["已切换{name}灯光模式", "Switched {name} light mode"],
  "已切换{name}模式": ["已切换{name}模式", "Switched {name} mode"],

  // Regions
  "中国大陆 (cn)": ["中国大陆 (cn)", "China Mainland (cn)"],
  "欧洲 (de)": ["欧洲 (de)", "Europe (de)"],
  "印度 (i2)": ["印度 (i2)", "India (i2)"],
  "俄罗斯 (ru)": ["俄罗斯 (ru)", "Russia (ru)"],
  "新加坡 / 国际 (sg)": ["新加坡 / 国际 (sg)", "Singapore / Global (sg)"],
  "美区 (us)": ["美区 (us)", "United States (us)"],

  // Skins, heights, sizes, comfort, effects, fans
  "经典": ["经典", "Classic"],
  "霜白": ["霜白", "Frost"],
  "夜航": ["夜航", "Night flight"],
  "液态玻璃": ["液态玻璃", "Liquid glass"],
  "柔雾": ["柔雾", "Soft mist"],
  "便当格": ["便当格", "Bento"],
  "霓虹夜": ["霓虹夜", "Neon night"],
  "胶囊": ["胶囊", "Capsule"],
  "晨光": ["晨光", "Dawn"],
  "紧凑": ["紧凑", "Compact"],
  "标准": ["标准", "Standard"],
  "加高": ["加高", "Tall"],
  "最大": ["最大", "Max"],
  "半行": ["半行", "Half row"],
  "整行": ["整行", "Full row"],
  "展开面板": ["展开面板", "Expanded panel"],
  "偏热": ["偏热", "Warm"],
  "偏冷": ["偏冷", "Cool"],
  "偏干": ["偏干", "Dry"],
  "偏湿": ["偏湿", "Humid"],
  "舒适": ["舒适", "Comfortable"],
  "日光": ["日光", "Daylight"],
  "月光": ["月光", "Moonlight"],
  "无": ["无", "None"],
  "温馨": ["温馨", "Cozy"],
  "观影": ["观影", "Movie"],
  "阅读": ["阅读", "Reading"],
  "电脑": ["电脑", "Computer"],
  "会客": ["会客", "Guests"],
  "娱乐": ["娱乐", "Entertainment"],
  "起床": ["起床", "Wake up"],
  "黄昏": ["黄昏", "Dusk"],
  "睡眠": ["睡眠", "Sleep"],
  "低": ["低", "Low"],
  "中": ["中", "Medium"],
  "高": ["高", "High"],
  "{level} 档": ["{level} 档", "Level {level}"],
  "取暖": ["取暖", "Heating"],
  "地暖": ["地暖", "Floor heating"],
  "空调": ["空调", "Air conditioner"],
  "风扇": ["风扇", "Fan"],
  "灯": ["灯", "Light"],
  "循环扇": ["循环扇", "Circulator"],
  "温湿度计": ["温湿度计", "Thermo-hygrometer"],
  "温度计": ["温度计", "Thermometer"],
  "温湿度": ["温湿度", "Temperature & humidity"],
  "扫地": ["扫地", "Vacuum"],
  "扫拖": ["扫拖", "Vacuum & mop"],
  "米家智能温湿度计": ["米家智能温湿度计", "Mi Smart Thermo-hygrometer"],

  // Cloud client errors
  "小米账号服务响应非 JSON": ["小米账号服务响应非 JSON", "Xiaomi account service returned non-JSON"],
  "小米账号服务返回 HTTP {status}": ["小米账号服务返回 HTTP {status}", "Xiaomi account service returned HTTP {status}"],
  "扫码结果非 JSON": ["扫码结果非 JSON", "QR result was not JSON"],
  "扫码结果缺少字段 (code {code})": ["扫码结果缺少字段 (code {code})", "QR result is missing fields (code {code})"],
  "缺少二维码字段 (code {code})": ["缺少二维码字段 (code {code})", "Missing QR fields (code {code})"],
  "登录成功但未拿到 serviceToken，请重试": ["登录成功但未拿到 serviceToken，请重试", "Signed in but no serviceToken was returned; please retry"],
  "米家云响应无法解密": ["米家云响应无法解密", "Mi Cloud response could not be decrypted"],
  "米家云解密后非 JSON": ["米家云解密后非 JSON", "Decrypted Mi Cloud payload was not JSON"],
  "米家云指令失败 ({code})：{message}": ["米家云指令失败 ({code})：{message}", "Mi Cloud command failed ({code}): {message}"],
  "米家云服务 HTTP {status}": ["米家云服务 HTTP {status}", "Mi Cloud service returned HTTP {status}"],
  "米家登录已过期，请重新扫码": ["米家登录已过期，请重新扫码", "The Mi Home session expired; scan again"],

  // Camera (#97)
  "客厅摄像机": ["客厅摄像机", "Living Room Camera"],
  "点击放大打开摄像机实时画面": ["点击放大打开摄像机实时画面", "Click to open live camera view"],
  "放大实时画面": ["放大实时画面", "Open Live View"],
  "镜头休眠": ["镜头休眠", "Sleep"],
  "唤醒镜头": ["唤醒镜头", "Wake"],
  "移动侦测：开": ["移动侦测：开", "Motion: On"],
  "移动侦测：关": ["移动侦测：关", "Motion: Off"],
  "米家云直连摄像头采用私有 P2P 加密流；可在下方填写本地 go2rtc / HLS 流地址观看实时画面": ["米家云直连摄像头采用私有 P2P 加密流；可在下方填写本地 go2rtc / HLS 流地址观看实时画面", "Xiaomi Cloud cameras use private P2P streaming; enter a local go2rtc / HLS stream URL below to watch live"],
  "该机型未开放云端 HLS 流接口，可填写本地 go2rtc 流地址接入": ["该机型未开放云端 HLS 流接口，可填写本地 go2rtc 流地址接入", "This model does not expose a cloud HLS stream; enter a local go2rtc stream URL"],
  "米家云未返回实时流地址，可填写本地 go2rtc / HLS 地址观看": ["米家云未返回实时流地址，可填写本地 go2rtc / HLS 地址观看", "Xiaomi Cloud did not return a live stream URL; enter a local go2rtc / HLS URL"],
  "摄像机处于物理休眠状态": ["摄像机处于物理休眠状态", "Camera is in sleep mode"],
  "镜头已遮蔽，点击下方唤醒后即可查看实时画面": ["镜头已遮蔽，点击下方唤醒后即可查看实时画面", "Lens is covered; click below to wake the camera and watch live"],
  "唤醒镜头并观看": ["唤醒镜头并观看", "Wake & Watch Live"],
  "实时看护小窗预览": ["实时看护小窗预览", "Live Floating Monitor"],
  "AI 移动与看护侦测中 · 画面正常": ["AI 移动与看护侦测中 · 画面正常", "AI Motion & Baby Watch Active · Clear"],
  "实时画面流已就绪 · 窗口已置顶": ["实时画面流已就绪 · 窗口已置顶", "Live stream ready · Window pinned on top"],
  "可配置本地 go2rtc / HLS 流地址观看实时画面": ["可配置本地 go2rtc / HLS 流地址观看实时画面", "Configure a local go2rtc / HLS stream URL to watch live"],
  "填写 go2rtc / HLS 流地址": ["填写 go2rtc / HLS 流地址", "Set go2rtc / HLS Stream URL"],
  "实时画面": ["实时画面", "Live View"],
  "实时画面小窗": ["实时画面小窗", "Live View Window"],
  "配置流地址": ["配置流地址", "Configure stream URL"],
  "关闭画面": ["关闭画面", "Close live view"],
  "连接流地址": ["连接流地址", "Connect stream URL"],
  "已{action}{name}移动侦测": ["已{action}{name}移动侦测", "{action} motion detection on {name}"],
  "已将{name}设为{mode}": ["已将{name}设为{mode}", "Set {name} to {mode}"],
  "夜视关": ["夜视关", "Night Off"],
  "夜视开": ["夜视开", "Night On"],
  "自动夜视": ["自动夜视", "Auto Night"],
  "智能全彩": ["智能全彩", "Smart Color"],
  "全彩夜视": ["全彩夜视", "Full Color"],
  "休眠中 · 点击唤醒": ["休眠中 · 点击唤醒", "Sleeping · Click to Wake"],
  "监控中": ["监控中", "Monitoring"],
  "侦测开": ["侦测开", "Motion On"],
  "点击看画面": ["点击看画面", "Live View"],
  "正在握手并连接摄像机实时画面…": ["正在握手并连接摄像机实时画面…", "Negotiating P2P and connecting to live camera stream…"],
  "重新连接": ["重新连接", "Reconnect"],
  "实时画面连接失败，请点右上角重新连接": ["实时画面连接失败，请点右上角重新连接", "Live view failed to connect; use Reconnect at the top right"],

  // Air Purifier (#98)
  "最爱": ["最爱", "Favorite"],
  "手动": ["手动", "Manual"],
  "静音": ["静音", "Silent"],
  "优": ["优", "Excellent"],
  "良": ["良", "Good"],
  "轻度污染": ["轻度污染", "Moderate"],
  "中度污染": ["中度污染", "Poor"],
  "重度污染": ["重度污染", "Heavy"],
  "严重污染": ["严重污染", "Hazardous"],
  "空气质量": ["空气质量", "Air quality"],
  "滤芯余量": ["滤芯余量", "Filter life"],
};

export const LANGUAGE_STORAGE_KEY = "menumijia.windows.language";
export const TEMPERATURE_STORAGE_KEY = "menumijia.windows.temperatureUnit";

/** Every catalog key, for tests and tooling. */
export function catalogKeys(): string[] {
  return Object.keys(CATALOG);
}

export function catalogEntry(key: string): readonly [string, string] | undefined {
  return CATALOG[key];
}

let current: AppLanguage = "zh-Hans";

export function getLanguage(): AppLanguage {
  return current;
}

export function setLanguage(language: AppLanguage): void {
  current = language;
}

/** `zh-Hans`, `zh-Hant` and bare `zh` are Chinese; everything else is English. */
export function languageFromTag(tag: string): AppLanguage {
  const lower = tag.toLowerCase();
  return lower === "zh" || lower.startsWith("zh-") || lower.startsWith("zh_") ? "zh-Hans" : "en";
}

/** Resolves the picker value against the OS languages (`navigator.languages`). */
export function resolveLanguage(preference: LanguagePreference, navigatorLanguages: readonly string[]): AppLanguage {
  if (preference !== "system") return preference;
  for (const tag of navigatorLanguages) {
    if (tag.trim() !== "") return languageFromTag(tag);
  }
  return "zh-Hans";
}

/** BCP-47 tag handed to the speech recognizer so dictation speaks the UI's language (#52). */
export function speechLocaleFor(language: AppLanguage): string {
  return language === "en" ? "en-US" : "zh-CN";
}

/** UI language of the running panel; used for speech, locale-aware formatting and the picker. */
export function speechLocale(): string {
  return speechLocaleFor(current);
}

function fill(template: string, params: Readonly<Record<string, string | number>>): string {
  return template.replace(/\{(\w+)\}/g, (whole, name: string) =>
    Object.prototype.hasOwnProperty.call(params, name) ? String(params[name]) : whole,
  );
}

/**
 * Translates a Chinese template. Unknown keys return the Chinese text unchanged, so a missing entry
 * degrades to Simplified Chinese instead of an empty label; `i18n.test.ts` fails the build for any
 * `t("…")` call site without a catalog entry.
 */
export function t(template: string, params?: Readonly<Record<string, string | number>>): string {
  const entry = CATALOG[template];
  const text = entry ? (current === "en" ? entry[1] : entry[0]) : template;
  return params ? fill(text, params) : text;
}

/** Marker used by the catalog tests: `true` when a key is translated and differs from Chinese. */
export function isTranslated(key: string): boolean {
  const entry = CATALOG[key];
  if (!entry) return false;
  return entry[0] !== entry[1] || entry[0] === "English";
}
