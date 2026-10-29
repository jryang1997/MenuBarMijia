# 更新记录

## 1.1.3

### Windows 修复
- **修复每约 6 秒设备、房间和温湿度读数乱序（[#81](https://github.com/jryang1997/MenuBarMijia/issues/81)）**：1.1.2 仍直接采用云端返回的设备列表顺序。本版同步时按设备 ID 保留已有位置，更新实时状态，新增设备追加到末尾，移除已不存在的设备；已有拖拽排序继续优先。保存稳定顺序到设备缓存，重启后的首次同步也沿用缓存位置。
- **补齐轮询回归场景**：交替反转设备和房间列表，同时改变亮度和温度，验证磁贴、房间标签、温湿度读数的位置稳定；覆盖设备增删、部分自定义排序和缓存恢复。
- 本次行为修复仅影响 Windows，macOS 仅同步版本号。

## 1.1.2

### Windows 修复
- **控制中心不再因米家云轮询反复重绘（[#81](https://github.com/jryang1997/MenuBarMijia/issues/81)）**：相同快照不再触碰界面；亮度、功率和环境读数等值变化改为原位更新，保留正在操作的控件、输入草稿和键盘焦点。结构变化仅在安全时重绘，并恢复无 ID 设备控件与滑块的焦点。
- **并发与交互保护**：较旧的刷新响应不会覆盖用户刚完成的控制或撤销；拖动期间暂停 DOM 更新，松开后补上；展开详情抽屉不会无限期阻塞结构更新；命令提交后输入框清空并恢复焦点。
- **Windows 安装包**：本次行为修复仅影响 Windows；macOS 包仅同步版本号，不包含新的 macOS 行为改动。

## 1.1.1

### 安全与凭据
- **macOS 钥匙串单条目保险库与升级引导（[#16](https://github.com/jryang1997/MenuBarMijia/issues/16), [#80](https://github.com/jryang1997/MenuBarMijia/pull/80)）**：将米家登录会话、Home Assistant 令牌、各 AI 服务商 API Key 及 LG 电视指纹合并保存在单个钥匙串条目（`CredentialVault`）中，升级版本后首次启动先展示说明，最多只需授权一次钥匙串访问。
- **防止旧版明文覆盖钥匙串与写入失败丢凭据（[#73](https://github.com/jryang1997/MenuBarMijia/pull/73), [#77](https://github.com/jryang1997/MenuBarMijia/pull/77)）**：钥匙串已有凭据时不再被残留旧明文覆盖；钥匙串或 Windows 凭据管理器写入失败时保留原有已存凭据。
- **Windows 原生 HTTP 来源白名单收归宿主管理（[#74](https://github.com/jryang1997/MenuBarMijia/pull/74), [#79](https://github.com/jryang1997/MenuBarMijia/pull/79)）**：仅允许访问已保存设置中的小米云、AI 服务商与 Home Assistant 地址，不再接受前端 WebView 自行放行新域名或跨源重定向。
- **NAS 部署包摘要校验与停服前预检（[#72](https://github.com/jryang1997/MenuBarMijia/pull/72)）**：`nas/deploy_ha.sh` 与 `nas/remote_setup.sh` 强制校验本地与远端归档 SHA-256、限制远端临时目录权限为 700，并在镜像拉取与标签准备成功前不停止既有 Home Assistant 容器。

### 交互与可靠性
- **点击外部区域收起菜单栏面板**：在桌面或其他应用窗口点击鼠标左键或右键时自动收起控制面板。
- **从系统设置返回时刷新通知权限（[#55](https://github.com/jryang1997/MenuBarMijia/issues/55), [#78](https://github.com/jryang1997/MenuBarMijia/pull/78)）**：不在启动瞬间弹出系统通知授权框；用户在系统设置更改通知权限并切回 App 时自动同步最新状态。
- **撤销操作按属性与家庭隔离（[#75](https://github.com/jryang1997/MenuBarMijia/pull/75)）**：撤销只恢复该次动作修改的属性，保留用户随后手动调整的其他属性，并在切换家庭后丢弃旧家庭的待撤销动作。
- **离线插座不再写入缓存功率（[#76](https://github.com/jryang1997/MenuBarMijia/pull/76)）**：设备离线时跳过缓存电表读数，避免虚增用电统计。
- **繁体中文回执与发布脚本修复（[#69](https://github.com/jryang1997/MenuBarMijia/pull/69), [#72](https://github.com/jryang1997/MenuBarMijia/pull/72), [#82](https://github.com/jryang1997/MenuBarMijia/pull/82)）**：补齐定时描述、助手执行回执、风速与华氏温差的繁体中文翻译；移除 `Bundle.module` 编译期绝对路径引用，修复云端 macOS 发布包残留 `/Users/` 路径导致发布门禁失败的问题；轮换离线 Ed25519 更新签名密钥并改存维护者系统钥匙串（macOS 代码签名证书保持不变）。

## 1.1.0

- 降低重复设备快照引起的界面刷新，设备别名先在临时列表中应用，再比较最终状态。回归验证相同快照不触发界面状态失效，实际状态和亮度变化仍正常更新。作者报告的 CPU 降幅尚未独立复现。

### 安全与隐私
- 首次配置固定发行签名证书和可用的离线更新签名密钥，私钥留在维护者本机；代码签名证书供发布 CI 使用。免费自签名发行未经过 Apple 公证，首次安装仍可能需要在系统设置中允许打开。
- **应用内更新有了独立的信任链，发布拆成草稿 → 离线签名 → Finalize（[#17](https://github.com/jryang1997/MenuBarMijia/issues/17)）**：更新包用离线 Ed25519 私钥签名，生成 `<DMG>.ed25519.sig`，公钥编进 App（`UpdateChecker.updateSigningPublicKeyBase64`，没有可配置公钥）；下载后先校验 SHA-256，再验证签名，缺失或不匹配一律中止安装。私钥不进 CI：`release.yml` 打标签只生成**草稿**（恰好 6 个构建附件，缺 `.sig` 时提示「等待离线签名」），维护者在本机用 `scripts/sign_update.swift` 签名并显式上传公有 `.sig`，再由 `.github/workflows/finalize.yml`（手动 `workflow_dispatch`）校验 tag/版本四处一致、远程 tag 指向、草稿状态、7 个附件字节与服务端 digest，并用内置公钥验签，最后只做 `gh release edit --draft=false`——不重编译、不上传、不 `--clobber`；缺 `.sig` 或验签失败（包括 DMG 重建后仍挂旧签名）直接失败，两个工作流都不读取 `MENUBARMIJIA_UPDATE_SIGNING_KEY`。代码签名要求从只认 Bundle ID 改为钉住固定证书的 SHA-1（`Info.plist` 的 `MijiaCodeSignCertSHA1`）；pin 缺失或不是 40 位十六进制时要求退化为 `identifier … and never`，同 Bundle ID 的 ad-hoc 包同样被拒，不会退回 bundle-ID-only——本机 ad-hoc 开发包能运行，但装不了应用内更新，发布包必须用固定证书签名并带正确 pin。只有非 Apple 锚定的本地构建才会去掉 `com.apple.quarantine`，正式构建保留隔离属性交给 Gatekeeper。离线签名 CLI 见 `scripts/sign_update.swift`。
- **AI 服务商改为精确域名识别（[#19](https://github.com/jryang1997/MenuBarMijia/issues/19)）**：`openrouter.ai.evil.com`、`notopenrouter.ai` 这类仿冒地址不再被当成 OpenRouter，也拿不到你保存的 Key。自定义地址的 Key 只发给保存时的那台服务器；换地址要重新填。非 https 的公网地址一律不发送（本机和局域网除外）。macOS 与 Windows 共用 `Tests/Fixtures/provider_golden.json` 校验。
- **不再自动读取 CodexBar / 环境变量里的 Key（[#20](https://github.com/jryang1997/MenuBarMijia/issues/20)）**：改为设置里的「从 CodexBar / 环境变量导入 Key」按钮，点了才读取并复制到本机钥匙串；设置里显示来源，可一键撤销。第一次要把指令发给某个云端 AI 服务前，会先问你一次（说明发送什么、发给谁），之后可在隐私设置里撤销授权。本机/局域网模型不用确认。升级后如果之前靠 CodexBar 自动接入，需要点一次导入。
- **AI 没把握时不再自己动手（[#21](https://github.com/jryang1997/MenuBarMijia/issues/21)）**：Jev 等 AI 给出的动作，只有把握 ≥ 80% 才直接执行；低于 80%、或没给出把握度的，变成建议胶囊，点一下才执行。打开电暖器、开关插座、启动扫地机即使 AI 很有把握也要点一下（关电暖器不用）。聊天类模型（DeepSeek 等）同样适用，回执不再声称已经开了还没开的设备。macOS 与 Windows 同步。
- **Home Assistant 断线后不再自己换地址（[#18](https://github.com/jryang1997/MenuBarMijia/issues/18)）**：以前连不上时会扫描局域网，把访问令牌直接发给扫到的第一台“Home Assistant”（可能是别人伪装的）。现在只在面板顶部提示「发现了 xxx，要切换过去吗？」，点「切换」才换；点「不切换」本次不再问。和你上次选的那台实例标识（uuid）不一致的直接忽略。连续断两次才扫描，最多 10 分钟一次。设置和新手引导里的「扫描」只填地址，点保存才连接。
- **凭证只存钥匙串，不再明文回退（[#16](https://github.com/jryang1997/MenuBarMijia/issues/16)）**：上一版为了绕开升级后的钥匙串弹窗，把米家会话、HA 令牌、AI API Key 和 LG 电视配对密钥都明文镜像到了 `UserDefaults`（`defaults read com.jryang1997.MenuBarMijia` 就能读到）。现在钥匙串是唯一存储：读取不再先看明文，读到钥匙串后也不再回写；保存空值即删除。升级后首次启动会自动把旧明文键（`ha_fallback_token`、`mi_session_fallback_v1`、`keychain_fallback_*`、`lg_webos_client_key`）迁入钥匙串并删除原键，钥匙串写入失败时保留明文等下次重试。由于 App 是 ad-hoc 自签名构建，升级后系统可能询问一次钥匙串访问；拒绝授权则需重新登录一次。Windows 版保持凭据管理器存储，不受影响。
- **演示模式严格离线，不再有任何外发请求（[#47](https://github.com/jryang1997/MenuBarMijia/issues/47)）**：演示模式的「检查更新」「下载更新」「测试 AI 连接」「主动建议」以及局域网 HA 扫描、LAN 电视连接等入口都先判断后端，一旦处于演示模式就直接返回本地结果或提示，不发起任何网络请求。切回演示模式时会停止正在运行的 LAN 电视链路、取消更新任务并清理已暂存的更新包，避免上一个后端遗留的网络活动继续跑；离开演示模式后再恢复 LAN 电视连接。设置页与面板会提示「演示模式不联网，请切换数据源后…」。
- **LG 电视连接固定证书，HA 明文地址会提示（[#30](https://github.com/jryang1997/MenuBarMijia/issues/30)）**：首次连接 webOS 电视时把该次 TLS 叶证书的 SHA-256 按电视 host 存进钥匙串；之后证书变化就直接拒绝连接、停止重试并在面板弹出提示，不会再默默信任新证书。设置里新增「重新信任电视」，二次确认后清除旧证书与配对密钥，并要求在电视上重新确认配对；已保存的指纹读不出来或写入失败时同样按失败关闭处理，不会降级成「信任任何证书」。另外，HA 地址如果是 `http://` 且不是本机回环地址，设置页与新手引导会显示橙色提示（令牌将明文传输），占位符改为推荐 `https://` 或 Nabu Casa 地址。
- **米家会话不再保存账号级 `passToken`（[#27](https://github.com/jryang1997/MenuBarMijia/issues/27)）**：`passToken` 全仓库没有一处使用，会话过期一直是提示重新扫码，所以登录成功后不再持久化它；迁移旧会话时会解码后重新编码，把已存的 `passToken` 一并去掉，不需要重新登录。决策见 `docs/adr/0004-no-pass-token-storage.md`。

### 防误操作
- **「全关」更安全（[#23](https://github.com/jryang1997/MenuBarMijia/issues/23)）**：只关当前看到的设备（当前房间、未隐藏）；插座和扫地机默认不参与（插座常接路由器、冰箱、鱼缸，扫地机不该被打断回充），可在设备右键菜单里单独加入或排除，Windows 在设置里勾选。所有皮肤都改为按住 0.6 秒才执行（经典皮肤以前单击就关），按钮显示范围和台数，例如「全关·书房 (2)」。撤销横幅从 5 秒延长到 10 秒。VoiceOver 可用「关闭这 N 台设备」操作。

### 可靠性
- **米家云不再全天每 6 秒拉一次数据（[#26](https://github.com/jryang1997/MenuBarMijia/issues/26)）**：面板打开时 6 秒刷新；面板关着改成 1 分钟一次（低电量模式 3 分钟）；电脑睡眠、显示器睡眠、锁屏、切换用户时完全不请求，醒来或解锁后马上刷新一次。选了某个家庭时只拉这个家庭的设备。米家云提示请求太频繁（HTTP 429）时至少等 1 分钟再试、最长 15 分钟，并在面板上提示。想核对请求量，可在「控制台」App 搜 `Mi cloud polling`，每次切换都会记下之前拉了几次。Windows：面板打开 12 秒、收在托盘里 1 分钟。
- **合盖睡眠后，错过的定时不再一开盖就执行（[#22](https://github.com/jryang1997/MenuBarMijia/issues/22)）**：定时到点时如果已经晚了 1 分钟以上（通常是电脑在睡眠），不会自动执行，而是和“启动时发现过期”一样进入「已错过」提示并发通知，由你决定立即执行或忽略。晚几秒的照常执行。Windows 同步。

### 交互、数据与工程
- **菜单栏改用公开 AppKit 接口（#56）**：自建 NSStatusItem 与 NSPanel，保留图标状态、悬停摘要、全局热键和按住说话，移除私有 KVC 与私有选择器。
- **拼音搜索（#60）**：输入或 ⌘F 搜设备名、房间与拼音首字母；方向键选择、回车切换、右箭头展开，Esc 先清空再收起。
- **语言资源与温度单位（#52）**：新增繁体中文资源和可扩展语言表；界面按区域显示摄氏/华氏，设备协议仍使用摄氏；Windows 新增中英切换及跟随界面的语音语言。
- **本地用电记录（#62）**：按插座累计电表读数记录增量，显示七日用电与设备排行，支持电价和清除；无电表读数不估算，首次记录不回填历史。
- **快捷指令、URL 与 Mac 自动化（#57/#59）**：复用现有控制与撤销路径，URL 默认确认；自动化默认无规则，一分钟去重且不训练习惯。打包必须包含 App Intents 元数据。
- **HomeStore 按职责拆分（#48）**：主文件降到 439 行，连接、控制、指标、提醒、撤销、界面状态分别维护。
- **发布与 Mac 验收**：补充严格附件门禁、离线签名后的手动 Finalize 和 Mac 交接清单；Homebrew cask 与同步工作流已备妥，公开 tap 与跨仓库凭据尚未配置。部分 macOS 交互已完成系统快捷指令、搜索、温度单位、撤销和真实书房灯验收；未覆盖项目与发行签名边界见 `docs/qa/mac-acceptance-2026-10-27.md`。

## 1.0.6

本次提供 macOS (`MenuBarMijia-1.0.6.dmg`) 与 Windows 安装包。

### 新增与改进
- **macOS 应用内一键下载、校验、安装与重启更新 ([#4](https://github.com/jryang1997/MenuBarMijia/issues/4), [#5](https://github.com/jryang1997/MenuBarMijia/pull/5))**：在「软件更新」区域展示新版本号与可折叠的更新说明；点击「下载并安装」后直接在应用内流式下载 GitHub Releases 安装包（优先 `.dmg`，次选 `.zip`），分块校验 SHA-256 摘要，后台静默挂载解包，剥离 `com.apple.quarantine` 并通过 `codesign --verify --deep --strict` 校验 Bundle ID 与代码签名。校验通过后由用户点击「立即重启完成更新」完成原位替换与自动重启，无需手动挂载 DMG 拖入 `/Applications`。
- **自动检查更新开关与底栏轻量角标提醒 ([#4](https://github.com/jryang1997/MenuBarMijia/issues/4))**：新增「自动检查更新」偏好开关（默认开启，按 24 小时节流），在面板底栏以胶囊角标静默提示新版本或就绪状态，不弹出打断当前工作的系统模态窗口；下载失败或无写入权限时保持当前版本正常运行，并提供「重试」与「手动下载 DMG」兜底按钮。
- **跨版本更新无感保留登录态、钥匙串凭据与自定义配置 ([#4](https://github.com/jryang1997/MenuBarMijia/issues/4))**：为米家云登录会话 (`MiSessionStore`) 与各 AI 服务商 API Key (`KeychainHelper`) 补齐 `UserDefaults` 回退同步及 `kSecUseAuthenticationUISkip` 非阻塞查询，在应用启动及替换重启前自动同步凭据，消除 Ad-hoc 签名跨版本更新后的 macOS 钥匙串授权弹窗。

## 1.0.5

本次提供 macOS (`MenuBarMijia-1.0.5.dmg`) 与 Windows 安装包。

### 修复
- **修复自定义 `localhost:3425` / `127.0.0.1:3425` 兼容接口保存后被重置为 OpenRouter 的问题 ([#3](https://github.com/jryang1997/MenuBarMijia/issues/3))**：移除 `AssistantConfig.load(from:)` 中无条件拦截 `localhost:3425` 与 `127.0.0.1:3425` 的旧版遗留覆盖逻辑，完整保留用户显式保存的自定义 Base URL、模型与对应服务商槽位的 API Key。
- **统一「测试连接」与语音/文字指令执行的配置解析路径 ([#3](https://github.com/jryang1997/MenuBarMijia/issues/3))**：`HomeStore.verifyAssistantConfig(_:)` 与设置面板保存操作现统一读取持久化后的 `store.assistantConfig`（`AssistantConfig.load(from: userDefaults)`），确保「测试连接」与实际 AI 指令执行使用完全相同的生效端点、模型及凭据，消除测试假阳性；同时为非 `.standard` 的测试 `UserDefaults` 增加独立密钥存储隔离，并补充 `127.0.0.1:3425` 与 `localhost:3425` 保存/读取往返及端到端执行回归测试。

## 1.0.4

本次提供 macOS (`MenuBarMijia-1.0.4.dmg`) 与 Windows 安装包。

### 修复与新增
- **修复米家扫码登录后菜单栏图标消失 / 进程闪退问题 ([#2](https://github.com/jryang1997/MenuBarMijia/issues/2))**：定位并修复 `MiCloudProvider.loadMissingSpecs()` 在 Release (`-O`) 编译优化下，因 `withTaskGroup` 子任务直接返回内联异步挂起点的三元组 `return (model, try await source.spec(...), nil)`，触发 Swift 6.4 协程分片优化消除元组首字段（`model`）写入、进而导致未初始化内存解引用 `EXC_BAD_ACCESS (SIGBUS)` 闪退或全部设备规格被跳过（`0 supported`）的问题。现改为先完成 `await` 再构造具名 `SpecLoadOutcome` 结构体，并补充 20+ 模型并发加载回归测试与 `scripts/check.sh` 静态门禁。
- **多 AI 服务商一键切换与自有 API Key 支持（macOS & Windows 双端对齐）**：不再局限于复用 CodexBar 中的 OpenRouter 密钥，现内置 **TypeSafe Jev 官方 (`https://api.typesafe.ai/v1`)**、**OpenRouter (`~typesafe/jev-latest`)**、**DeepSeek (`deepseek-chat`)**、**通义千问 Qwen**、**智谱 GLM**、**Moonshot Kimi**、**硅基流动 SiliconFlow**、**OpenAI**、**Groq**、**Ollama 本地模型** 及自定义 OpenAI 兼容端点预设。用户可在设置页或新手引导直接填入自己的 API Key，切换服务商时自动填入推荐 Base URL 与模型名；Jev 模型自动调用 `/v1/systemone` 结构化多选决策接口，DeepSeek 等通用模型自动调用 `/v1/chat/completions` JSON 规划接口。

## 1.0.3

本次提供 macOS (`MenuBarMijia-1.0.3.dmg`) 与 Windows 安装包。

### 新增与改进
- **系统门槛下放至 macOS 14+ (Sonoma / Sequoia / Tahoe)**：将 `Package.swift` 与应用打包最低系统版本从 `macOS 26.0` 下调至 `macOS 14.0`。macOS 26 保持原生 SwiftUI `.glassEffect` Liquid Glass 液态玻璃渲染，macOS 14 与 15 自动回退至 `.ultraThinMaterial` 毛玻璃；核心库 `MijiaCore` 可直接作为独立 SwiftPM 库引用。
- **定时器磁盘持久化与过期安全确认**：延时指令（如「10 分钟后关加热器」）持久化保存在本地 `UserDefaults` (`assistant_scheduled_commands_v1`)。应用重启后，未到期定时按剩余秒数继续倒计时；退出期间已过期的定时转入待确认队列（绝不在后台静默触发过期硬件操作），通过指令栏顶部横幅与 macOS 原生通知提供「立即执行」或「忽略」。
- **双端黄金语料 (`intent_golden.json`) 与 Windows 英文指令完整对齐**：新增跨平台共享测试语料 `Tests/Fixtures/intent_golden.json`，由 Swift Testing 与 Windows TypeScript 测试共同校验；Windows 端补齐词边界消费式英文解析（支持色温、空调模式、相对调温、自动风速、英文延时与撤销）。
- **隐私与米家云直连说明完善**：在 README 与登录设置页补充米家非官方客户端 API 的账号风控提示与官方 `xiaomi_home` 替代方案，并披露本地 `UserDefaults` 明文存储键名。

## 1.0.2

本次提供 macOS (`MenuBarMijia-1.0.2.dmg`) 与 Windows 安装包。

### 新增
- **应用内中英双语国际化 (`zh-Hans` / `en`)**：支持「跟随系统 / 简体中文 / English」实时切换（偏好设置与新手引导均可一键切换），全面覆盖主控制面板、设备磁贴、快捷场景、设置页、安全通知与系统权限弹窗。
- **英文语音识别与本机 0ms 英文指令解析**：英文界面下自动切换 `en-US` 语音识别，支持英文自然语言设备控制（如 `"turn on study light"`, `"study light moonlight mode"`, `"set living room ac to 24 degrees"`, `"dimmer"`）、英文延时指令（`"in 10 minutes turn off study light"`, `"cancel timer"`）与英文撤销（`"undo"`, `"revert"`）。
- **米家云端多地区服务器选择**：扫码登录支持切换中国大陆 (`cn`)、新加坡/国际 (`sg`)、欧洲 (`de`)、美区 (`us`)、俄罗斯 (`ru`) 节点。

## 1.0.1

本次提供 macOS (`MenuBarMijia-1.0.1.dmg`) 与 Windows 安装包。

### 修复
- 应用名称、安装包（`MenuBarMijia.app` / `MenuBarMijia-1.0.1.dmg`）与仓库名称统一为 `MenuBarMijia`。
- LG webOS 电视局域网直连默认关闭，移除内置的局域网 IP 与 MAC 地址默认值，改为由用户在设置中填写或局域网扫描。
- 未配置 AI 服务 API Key 时，默认地址保持为 OpenRouter (`https://openrouter.ai/api/v1`)，不再回退连接本机 `localhost:3425` 端口，并在触发复杂指令时直接提示配置 API Key（简单指令仍可 0ms 本地离线执行）。
- Home Assistant 支持独立实体的设备合成，补齐没有物理设备注册记录的灯、风扇、空调、插座等已支持类型。
- 按 Home Assistant 的标准设备类别识别温湿度计和普通开关，保留辅助开关设备的环境读数，避免实体名子串误伤有效插座。
- 初次连接等待区域、设备、实体注册表和状态全部就绪后发布列表，避免隐藏设备暂时出现；注册表权限或格式错误会显示连接错误。
- Windows 云端控制失败时显示错误并保留原状态；撤销按成功指令逆序恢复实际修改的属性和原始开关状态，失败后可重试。
- Windows 保留手动选择的数据源，避免已有小米登录信息覆盖该选择；同步设备时不再重叠请求。
- Windows 灯具详情显示设备支持的日光、月光等模式，点击后通过米家云切换，并支持撤销恢复原模式。

### 工程
- 固定 Windows 原生依赖版本；CI 在核心测试通过后生成安装包和 SHA-256 校验文件，发布时上传到对应版本。
- 增加 Windows 页面控制、模式切换及撤销回归测试，以及 HA 设备识别、初始返回顺序和注册表错误的 Swift Testing 用例。

## 1.0.0

### 新增
- 说「再暗一点」「调高两度」「温度低一点」可以微调；没说设备时只调正开着的。
- 风扇：「高档」「风速调低」「摇头」「停止摇头」。
- 定时：「10 分钟后关灯」「半小时后关空调」，指令栏里能看到倒计时并取消；也可以说「取消定时」。
- 语音撤销：说「撤销」能恢复 10 分钟内最近一次语音操作。
- 设置页「检查更新」，读取 GitHub Releases。
- 隐私：可以关掉习惯学习、逐条删除已记住的习惯、让语音只在本机识别；设置页写明哪些内容会发给 AI。

### 改进
- App 名称统一为 MenuBarMijia（登录信息和设置会保留）。
- AI 出错时说人话：超时、断网、密钥不对、请求太多、服务器出错分别提示。
- 默认家庭名改为「我的家」。

### 工程
- 版本号放在 `VERSION`；`scripts/release.sh` 一条命令完成签名、DMG、公证。
- GitHub Actions：macOS 上编译和测试，Linux 上跑核心测试。
- 核心库可以在 Linux 上编译测试（`scripts/linux-check/run.sh`）。
- `HomeStore.swift` 拆出 `HomeStore+Assistant.swift`。
