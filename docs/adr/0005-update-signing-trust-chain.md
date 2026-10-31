# ADR-0005：应用内更新的信任链改为 Ed25519 更新签名 + 固定代码签名证书

日期：2026-10-27　状态：已接受（对应审计 #17）

## 背景

在此之前，应用内更新的信任只落在 GitHub 一处：

- 期望的 SHA-256 来自 GitHub API 的 asset digest，或同一个 release 里的 `.sha256`；
- 安装前的 `codesign` 要求只有 `identifier "com.jryang1997.MenuBarMijia"`，任何人都能用同一个 Bundle ID 做 ad-hoc 签名；
- 解包后无条件执行 `xattr -dr com.apple.quarantine`，主动绕过 Gatekeeper。

威胁模型很直接：GitHub 账号、Token 或 CI 任意一环被拿下（参见 #25：`contents: write` 且 main 无保护），攻击者就能发一个新 release、附上匹配的 `.sha256` 与同 ID 的 ad-hoc 签名包，让所有开启了自动更新的用户装上恶意版本且不经过 Gatekeeper。项目已有真实用户与下载量，这是全项目影响面最大的链路。

## 决定

1. **Ed25519 分离签名，作为主防线。** 发布时用私钥对最终安装包字节签名，生成 `<安装包>.ed25519.sig` 并作为 release 附件上传。双端应用把同一 32 字节公钥编进源码（macOS `UpdateChecker.updateSigningPublicKeyBase64`、Windows `UPDATE_SIGNING_PUBLIC_KEY_BASE64`），在下载完成、SHA-256 校验通过之后、解包或启动安装程序之前验证签名。签名缺失、不是合法 base64、或与包内容不匹配，一律中止安装并报明确错误（`updateSignatureMissing` / `updateSignatureInvalid`）。macOS 侧选择 CryptoKit `Curve25519.Signing`（Linux 侧由 ADR-0003 的 swift-crypto 垫片提供同名 API）；Windows 侧复用 `rustls` 已引入的 `ring::signature::ED25519` 验签。

   私钥的保存方式决定这条防线到底防谁：**私钥只保存在维护者的可信本机，永不进入 GitHub**。`release.yml` 与 `finalize.yml` 都不读取 `MENUBARMIJIA_UPDATE_SIGNING_KEY`，CI 里也没有该 secret，因此 GitHub 账号、Token 或 CI 任意一环被拿下都拿不到签名私钥，攻击者最多造成“更新失败”，而不是“装上恶意版本”。代价是发布必须多一次人工离线签名（见下文第 4 条）。

2. **钉住代码签名证书。** 项目没有付费 Apple 开发者账号，发布包用固定的自签名代码签名证书（RSA 3072，10 年，Code Signing EKU）。`scripts/build_app.sh` 在设置了 `MACOS_SIGNING_IDENTITY` 时用该身份签名（未显式设置时优先自动使用本机钥匙串中的 `"MenuBarMijia Release Signing"`，找不到才退回 ad-hoc `-`），并把证书 SHA-1（`MACOS_CERT_SHA1`）写进 App 的 `Info.plist` 键 `MijiaCodeSignCertSHA1`。更新时读取运行中 App 的该键，把 `codesign` 要求构造成：

   ```
   identifier "com.jryang1997.MenuBarMijia" and certificate leaf = H"<sha1>"
   ```

   同 Bundle ID 的 ad-hoc 包没有这张证书，无法通过。**这里刻意不使用 `anchor apple generic`**：自签名证书不链到 Apple，加上 anchor 会让所有正式签名更新永远匹配不上；精确钉住叶子证书哈希本身就是信任锚。缺少 `MijiaCodeSignCertSHA1`、或该值不是 40 位十六进制时，要求退化为 `identifier "<bundle id>" and never`，也就是**任何**包都校验失败（包括同 Bundle ID 的包），**不会退回 identifier-only**。这是 fail-closed 取舍：本机 ad-hoc 开发包照常运行，但装不了应用内更新；发布包必须带正确的证书 pin，`scripts/release.sh` 在缺少非 ad-hoc 签名身份或 pin 不匹配时直接拒绝出包。

   把证书 p12 放进 GitHub secret 的残余风险是：CI 被攻破时攻击者可以签出“看起来同源”的 App 包；但 Ed25519 私钥从不进入 CI，攻击者仍然产不出能通过 `finalize.yml` 验签的 `.ed25519.sig`。因此 p12 泄露不足以投放恶意更新，私钥的保管方式才是最终门槛。代码签名证书（`MACOS_SIGNING_P12`、`WINDOWS_CERTIFICATE`）与更新签名私钥是两类凭据，前者留在 CI，后者永不进入 CI。

3. **隔离属性按构建类型处理。** 新增纯函数 `AppUpdater.shouldStripQuarantine(currentAppIsAdHoc:)`：只有非 Apple 锚定的构建（ad-hoc 或自签名、本地开发）才去掉 `com.apple.quarantine`，保证本地自更新可用；Apple 锚定的正式构建保留隔离属性，让 Gatekeeper 正常检查替换后的 App。`currentAppIsAdHoc()` 用 `SecCodeCopySelf` → `SecCodeCopyStaticCode` → `SecCodeCopyDesignatedRequirement` → `SecRequirementCopyString` 判断 designated requirement 是否含 `anchor apple generic`；读取失败时保守地当作 ad-hoc（维持本地更新，不让功能因环境差异失效）。代价是自签名发布包仍会去隔离——这类包本来也无法通过 Gatekeeper 公证检查，保留隔离只会让自更新直接失败。

4. **发布拆成两阶段：CI 只产草稿，人工离线签名，再由 Finalize 校验后发布。**

   - **阶段一（`release.yml`，push tag `v*` 或 workflow_dispatch 输入 `tag`）**：`verify-tag` → `macos-release` / `windows-release` → `stage-draft`。构建 job 只上传 artifact；`stage-draft` 校验 6 个未签名附件（DMG、`.dmg.sha256`、EXE、`.exe.sha256`、MSI、`.msi.sha256`）、拒绝改动已发布的 release、创建或刷新**草稿**，并在缺 `.ed25519.sig` 时以“⏳ 等待离线签名”成功结束。`release.yml` 全文件没有 `--draft=false`，构建阶段无法发布。
   - **阶段二（维护者本机）**：下载草稿里的 DMG/EXE/MSI，用离线私钥执行 `scripts/sign_update.swift` 生成 3 份 `.ed25519.sig`（脚本要求私钥对应的公钥等于内置值），再用 `gh release upload <tag> dist/*.ed25519.sig` 显式上传这三个公有签名附件。
   - **阶段三（`finalize.yml`，仅手动 workflow_dispatch，输入 `tag`）**：校验 tag == `v$(VERSION)`、四处版本号一致、远程 tag 仍指向检出提交、目标必须是未发布草稿；下载**恰好 9 个**附件，逐个比对下载字节与草稿的服务端 `sha256:` digest 与大小，并用 `scripts/check_release.sh assets` 就地解析 `UpdateChecker.updateSigningPublicKeyBase64` 对 DMG/EXE/MSI 验签（没有可配置公钥，换密钥必须改源码并发新版）；最后只执行 `gh release edit --draft=false`，**不重编译、不上传、不 `--clobber`**。

   缺签名时 `stage-draft` 只留草稿；`finalize.yml` 发现草稿里缺少任一 `.sig` 会输出完整离线命令并以非零退出，验签失败（包括安装包重建后仍挂旧签名）同样硬失败。`draft-assets` 严格 6 个、`assets` 严格 9 个，多一个少一个都失败，因此“少签名”不会悄悄降级为不带签名的发布。私钥格式支持 32 字节 raw seed 的 base64 或 PKCS#8 PEM。

## 后果

- 私钥只在本机：GitHub 账号、release、CI 任一被攻破都无法产出能通过校验的更新包；攻击者最多造成“更新失败”或“发布被拖延”，而不是“装上恶意版本”。
- 发布流程固定多一步人工离线签名 + 手动触发 Finalize，换取更新链路的独立性。轮换密钥需要同时改 `UpdateChecker.updateSigningPublicKeyBase64` 并发布新版本；轮换代码签名证书同理，旧版本会因钉住旧证书而拒绝新包，需要先用旧证书发一个过渡版本。
- 残余风险：升级到本实现之前发布的旧版本仍按旧信任链检查更新，因此“第一次升级到带签名校验的版本”这一步无法由新机制保护；之后的所有更新才受 Ed25519 约束。
- 残余风险：攻击者可以重放一份**旧版本但签名有效**的 DMG，并把 release 标成更高版本号；版本号本身没有签名覆盖。当前缓解依赖 release 可见性与用户察觉，后续可把最低版本/渠道写进签名载荷再收紧。
- 残余风险：`stage-draft` 复用一个已有草稿并且重传了 DMG 时，草稿里会短暂留着旧 `.sig`（工作流只打 `::warning::`）。真正把关的是 `finalize.yml`：字节与签名不符会硬失败，因此这种状态无法发布出去。
- CI secret 里的 p12 / Authenticode 证书能签出同证书的 App 与安装包，但不能伪造更新签名；私钥泄露才是灾难性事件。
- 自签名构建仍会去隔离；这是“没有 Apple 公证”这一前提下的可用性取舍，而不是对 Gatekeeper 的普遍绕过。

## 相关

- #17（本 ADR 的来源）、#25（CI 权限与 release 覆盖风险）
- ADR-0003（MijiaCore 在 Linux 上编译，CryptoKit 由 swift-crypto 垫片提供）
- `Sources/MijiaCore/UpdateChecker.swift`、`Sources/MijiaCore/UpdateSignature.swift`、`scripts/sign_update.swift`、`scripts/build_app.sh`、`scripts/release.sh`、`scripts/check_release.sh`、`.github/workflows/release.yml`、`.github/workflows/finalize.yml`
