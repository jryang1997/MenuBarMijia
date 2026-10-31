#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use ring::digest::{digest, SHA256};
use ring::signature::{UnparsedPublicKey, ED25519};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{LazyLock, RwLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{
    menu::{Menu, MenuBuilder},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Manager, PhysicalPosition, PhysicalSize, WebviewWindow, WindowEvent,
};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};

static LAST_FOCUS_LOSS_MS: AtomicU64 = AtomicU64::new(0);
static PIN_POPOVER: AtomicBool = AtomicBool::new(false);

struct TrayAndHotkeyState {
    active_shortcut: Option<Shortcut>,
    shortcut_label: Option<String>,
    update_version: Option<String>,
}

static TRAY_AND_HOTKEY_STATE: LazyLock<RwLock<TrayAndHotkeyState>> = LazyLock::new(|| {
    RwLock::new(TrayAndHotkeyState {
        active_shortcut: None,
        shortcut_label: Some("Alt+M".to_string()),
        update_version: None,
    })
});

fn is_standalone_function_key(code: Code) -> bool {
    matches!(
        code,
        Code::F1
            | Code::F2
            | Code::F3
            | Code::F4
            | Code::F5
            | Code::F6
            | Code::F7
            | Code::F8
            | Code::F9
            | Code::F10
            | Code::F11
            | Code::F12
            | Code::F13
            | Code::F14
            | Code::F15
            | Code::F16
            | Code::F17
            | Code::F18
            | Code::F19
            | Code::F20
    )
}

/// Validates and parses a global shortcut string (#43).
/// Requires at least one modifier (`Ctrl`/`Alt`/`Shift`/`Super`) or a standalone `F1`–`F20` key.
fn parse_global_shortcut(raw: &str) -> Result<(Shortcut, String), String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("快捷键不能为空".to_string());
    }
    let shortcut = Shortcut::from_str(trimmed)
        .map_err(|_| format!("快捷键格式无效：{trimmed}"))?;
    if shortcut.mods.is_empty() && !is_standalone_function_key(shortcut.key) {
        return Err("快捷键需要包含 Ctrl / Alt / Shift / Win 修饰键，或使用 F1–F20".to_string());
    }
    Ok((shortcut, trimmed.to_string()))
}

/// Configured origins retain the protocol and port, so permission for one service
/// cannot authorize another service on the same host (#29).
static EXTRA_ALLOWED_ORIGINS: LazyLock<RwLock<HashSet<String>>> =
    LazyLock::new(|| RwLock::new(HashSet::new()));

const BUILT_IN_HOST_SUFFIXES: &[&str] = &[
    "account.xiaomi.com",
    "api.io.mi.com",
    "miot-spec.org",
    // Public release metadata for the update check (#39); no credentials are sent.
    "api.github.com",
];

/// Windows release page opened from the tray/update row (#39).
const RELEASE_PAGE_URL: &str = "https://github.com/jryang1997/MenuBarMijia/releases/latest";

fn normalize_host(raw: &str) -> String {
    raw.trim()
        .trim_end_matches('.')
        .trim_start_matches('[')
        .trim_end_matches(']')
        .to_ascii_lowercase()
}

fn url_origin(url: &reqwest::Url) -> Option<String> {
    if !matches!(url.scheme(), "http" | "https")
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return None;
    }
    let host = normalize_host(url.host_str()?);
    if host.is_empty() {
        return None;
    }
    let authority = if host.contains(':') {
        format!("[{host}]")
    } else {
        host
    };
    Some(format!(
        "{}://{}:{}", url.scheme(), authority, url.port_or_known_default()?
    ))
}

fn normalize_extra_origin(raw: &str) -> Option<String> {
    let url = reqwest::Url::parse(raw.trim()).ok()?;
    if url.path() != "/" || url.query().is_some() || url.fragment().is_some() {
        return None;
    }
    url_origin(&url)
}

fn check_url_allowed(url: &reqwest::Url, extra: &HashSet<String>) -> Result<(), String> {
    let origin = url_origin(url)
        .ok_or_else(|| "native_http 地址必须是无用户凭据的 http/https 地址".to_string())?;
    let host = normalize_host(url.host_str().unwrap_or_default());
    let built_in_host = BUILT_IN_HOST_SUFFIXES
        .iter()
        .any(|suffix| host == *suffix || host.ends_with(&format!(".{suffix}")));
    let allowed = if built_in_host {
        url.scheme() == "https" && url.port_or_known_default() == Some(443)
    } else {
        extra.contains(&origin)
    };
    if allowed {
        Ok(())
    } else {
        Err(format!("native_http 拒绝访问未授权来源：{origin}"))
    }
}

fn redirect_allowed(original_origin: &str, next: &reqwest::Url, extra: &HashSet<String>) -> bool {
    url_origin(next).as_deref() == Some(original_origin) && check_url_allowed(next, extra).is_ok()
}

fn allowed_origins_snapshot() -> Result<HashSet<String>, String> {
    EXTRA_ALLOWED_ORIGINS
        .read()
        .map(|origins| origins.clone())
        .map_err(|_| "origin allowlist unavailable".to_string())
}

const CREDENTIAL_SERVICE: &str = "com.jryang.menubarmijia";
const CREDENTIAL_NAMES: &[&str] = &["mi_session", "ha_token", "assistant_api_key"];

/// Fixed credential names only: this must not become a generic key/value store (#28).
fn allowed_credential_name(name: &str) -> Result<&str, String> {
    if CREDENTIAL_NAMES.contains(&name) {
        return Ok(name);
    }
    if let Some(suffix) = name.strip_prefix("assistant_api_key_") {
        if !suffix.is_empty()
            && suffix.len() <= 48
            && suffix
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
        {
            return Ok(name);
        }
    }
    Err(format!("不允许的凭据名称：{name}"))
}

fn credential_entry(name: &str) -> Result<keyring::Entry, String> {
    let name = allowed_credential_name(name)?;
    keyring::Entry::new(CREDENTIAL_SERVICE, name)
        .map_err(|error| format!("无法打开 Windows 凭据管理器：{error}"))
}

fn now_epoch_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn tray_labels_for_shortcut(shortcut_label: Option<&str>) -> (String, String) {
    match shortcut_label.map(str::trim).filter(|s| !s.is_empty()) {
        Some(label) => (
            format!("打开/隐藏控制中心 ({label})"),
            format!("MenuBarMijia · 菜单栏米家 ({label})"),
        ),
        None => (
            "打开/隐藏控制中心".to_string(),
            "MenuBarMijia · 菜单栏米家".to_string(),
        ),
    }
}

/// Rebuilds the tray menu, adding the "有新版本" entry only when a release is known (#39)
/// and showing the active global shortcut when enabled (#43).
fn build_tray_menu(
    app: &AppHandle,
    shortcut_label: Option<&str>,
    update_version: Option<&str>,
) -> tauri::Result<Menu<tauri::Wry>> {
    let (toggle_text, _) = tray_labels_for_shortcut(shortcut_label);
    let mut builder = MenuBuilder::new(app).text("toggle", toggle_text);
    if let Some(version) = update_version {
        builder = builder.text("update", format!("有新版本 v{version}，点击查看"));
    }
    builder.text("quit", "退出 MenuBarMijia").build()
}

fn refresh_tray_chrome(app: &AppHandle, shortcut_label: Option<&str>, update_version: Option<&str>) {
    let Some(tray) = app.tray_by_id("main-tray") else {
        return;
    };
    let (_, tooltip) = tray_labels_for_shortcut(shortcut_label);
    let _ = tray.set_tooltip(Some(tooltip));
    if let Ok(menu) = build_tray_menu(app, shortcut_label, update_version) {
        let _ = tray.set_menu(Some(menu));
    }
}

/// The only external URL the frontend may open: a MenuBarMijia release page on GitHub.
fn validated_release_url(raw: &str) -> Result<String, String> {
    let url = reqwest::Url::parse(raw).map_err(|_| "更新页面地址无效".to_string())?;
    if url.scheme() != "https" {
        return Err("更新页面只允许 https 地址".to_string());
    }
    let host = url
        .host_str()
        .map(normalize_host)
        .unwrap_or_default();
    if host != "github.com" {
        return Err(format!("拒绝打开非 GitHub 地址：{host}"));
    }
    if !url.path().starts_with("/jryang1997/MenuBarMijia/releases") {
        return Err("拒绝打开非 MenuBarMijia 发布页".to_string());
    }
    Ok(url.to_string())
}

#[cfg(windows)]
#[link(name = "shell32")]
extern "system" {
    fn ShellExecuteW(
        hwnd: *mut core::ffi::c_void,
        operation: *const u16,
        file: *const u16,
        parameters: *const u16,
        directory: *const u16,
        show_cmd: i32,
    ) -> isize;
}

#[cfg(windows)]
fn open_url_in_browser(url: &str) {
    use std::os::windows::ffi::OsStrExt;

    let wide = |value: &str| -> Vec<u16> {
        std::ffi::OsStr::new(value)
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    };
    let operation = wide("open");
    let file = wide(url);
    // ShellExecuteW returns a value > 32 on success; a failure has no useful recovery here.
    unsafe {
        ShellExecuteW(
            std::ptr::null_mut(),
            operation.as_ptr(),
            file.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            1,
        );
    }
}

#[cfg(not(windows))]
fn open_url_in_browser(_url: &str) {}

#[tauri::command]
fn open_release_page(url: String) -> Result<(), String> {
    let target = validated_release_url(&url)?;
    open_url_in_browser(&target);
    Ok(())
}

/// Offline Ed25519 public key (32-byte raw, base64) shared with `UpdateChecker.updateSigningPublicKeyBase64` (ADR-0005).
const UPDATE_SIGNING_PUBLIC_KEY_BASE64: &str = "rLwWXuP0sOZvgd/KusLTTmBXN9DAZ9EzPBNhFSn9yUo=";
const STAGED_INSTALLER_PREFIX: &str = "MenuBarMijia-update-";

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InstallerAssetPayload {
    name: String,
    download_url: String,
    #[allow(dead_code)]
    #[serde(default)]
    size_bytes: u64,
    sha256: Option<String>,
    checksum_url: Option<String>,
    signature_url: String,
}

/// Validates a GitHub release download URL for MenuBarMijia installer, `.sha256`, or `.ed25519.sig` sidecar assets.
fn validated_release_asset_url(raw: &str) -> Result<reqwest::Url, String> {
    let url = reqwest::Url::parse(raw.trim()).map_err(|_| "更新包下载地址无效".to_string())?;
    if url.scheme() != "https"
        || url.port_or_known_default() != Some(443)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err("更新包地址必须是无附加参数的 https://github.com 地址".to_string());
    }
    let host = url.host_str().map(normalize_host).unwrap_or_default();
    if host != "github.com" {
        return Err(format!("拒绝从非 GitHub 地址下载更新包：{host}"));
    }
    if !url
        .path()
        .starts_with("/jryang1997/MenuBarMijia/releases/download/")
    {
        return Err("拒绝下载非 MenuBarMijia 官方发布附件".to_string());
    }
    Ok(url)
}

fn release_asset_redirect_allowed(next: &reqwest::Url) -> bool {
    if next.scheme() != "https"
        || next.port_or_known_default() != Some(443)
        || !next.username().is_empty()
        || next.password().is_some()
    {
        return false;
    }
    let host = next.host_str().map(normalize_host).unwrap_or_default();
    host == "github.com"
        || host == "githubusercontent.com"
        || host.ends_with(".githubusercontent.com")
}

fn parse_sha256_hex(raw: &str) -> Option<String> {
    let token = raw.split_whitespace().next()?;
    let candidate = token
        .strip_prefix("sha256:")
        .or_else(|| token.strip_prefix("SHA256:"))
        .unwrap_or(token)
        .to_ascii_lowercase();
    if candidate.len() == 64 && candidate.chars().all(|c| c.is_ascii_hexdigit()) {
        Some(candidate)
    } else {
        None
    }
}

fn sanitize_installer_filename(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty()
        || trimmed.contains('/')
        || trimmed.contains('\\')
        || trimmed.contains(':')
        || trimmed.contains("..")
        || trimmed.chars().any(|c| c.is_control())
    {
        return Err("更新安装包文件名无效".to_string());
    }
    let lower = trimmed.to_ascii_lowercase();
    if !lower.ends_with(".exe") && !lower.ends_with(".msi") {
        return Err("仅支持 .exe 或 .msi 安装包".to_string());
    }
    Ok(trimmed.to_string())
}

fn compute_sha256_hex(bytes: &[u8]) -> String {
    let sum = digest(&SHA256, bytes);
    let mut out = String::with_capacity(64);
    for byte in sum.as_ref() {
        use std::fmt::Write;
        let _ = write!(&mut out, "{byte:02x}");
    }
    out
}

/// Decodes standard RFC 4648 base64 (ignoring surrounding whitespace).
fn decode_base64_strict(raw: &str) -> Option<Vec<u8>> {
    let cleaned: Vec<u8> = raw
        .bytes()
        .filter(|b| !b.is_ascii_whitespace())
        .collect();
    if cleaned.is_empty() || cleaned.len() % 4 != 0 {
        return None;
    }
    fn val(b: u8) -> Option<u8> {
        match b {
            b'A'..=b'Z' => Some(b - b'A'),
            b'a'..=b'z' => Some(b - b'a' + 26),
            b'0'..=b'9' => Some(b - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let mut out = Vec::with_capacity((cleaned.len() / 4) * 3);
    for (idx, chunk) in cleaned.chunks_exact(4).enumerate() {
        let is_last = idx + 1 == cleaned.len() / 4;
        let a = val(chunk[0])?;
        let b = val(chunk[1])?;
        match (chunk[2], chunk[3]) {
            (b'=', b'=') if is_last => {
                if (b & 0x0f) != 0 {
                    return None;
                }
                out.push((a << 2) | (b >> 4));
            }
            (c_byte, b'=') if is_last => {
                let c = val(c_byte)?;
                if (c & 0x03) != 0 {
                    return None;
                }
                out.push((a << 2) | (b >> 4));
                out.push((b << 4) | (c >> 2));
            }
            (b'=', _) | (_, b'=') => return None,
            (c_byte, d_byte) => {
                let c = val(c_byte)?;
                let d = val(d_byte)?;
                out.push((a << 2) | (b >> 4));
                out.push((b << 4) | (c >> 2));
                out.push((c << 6) | d);
            }
        }
    }
    Some(out)
}

/// Verifies a detached Ed25519 signature over `data` against `public_key_base64` (ADR-0005).
fn verify_ed25519_signature(
    signature_base64: &str,
    public_key_base64: &str,
    data: &[u8],
) -> Result<(), String> {
    let trimmed_sig = signature_base64.trim();
    if trimmed_sig.is_empty() {
        return Err("更新包缺少 Ed25519 数字签名（.ed25519.sig），已中止安装".to_string());
    }
    let key_bytes = decode_base64_strict(public_key_base64)
        .filter(|bytes| bytes.len() == 32)
        .ok_or_else(|| "内置 Ed25519 更新公钥无效".to_string())?;
    let sig_bytes = decode_base64_strict(trimmed_sig)
        .filter(|bytes| bytes.len() == 64)
        .ok_or_else(|| "更新包 Ed25519 数字签名格式无效，已中止安装".to_string())?;
    let public_key = UnparsedPublicKey::new(&ED25519, key_bytes);
    public_key
        .verify(data, &sig_bytes)
        .map_err(|_| "更新包 Ed25519 数字签名校验失败：签名与安装包内容不匹配，已中止安装".to_string())
}

fn sweep_stale_update_installers() {
    let Ok(entries) = std::fs::read_dir(std::env::temp_dir()) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        if name
            .to_str()
            .is_some_and(|s| s.starts_with(STAGED_INSTALLER_PREFIX))
        {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

fn launch_installer(installer_path: &std::path::Path) -> Result<std::process::Child, String> {
    let is_msi = installer_path
        .extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| ext.eq_ignore_ascii_case("msi"));
    let mut cmd = if is_msi {
        let mut c = std::process::Command::new("msiexec");
        c.arg("/i").arg(installer_path);
        c
    } else {
        std::process::Command::new(installer_path)
    };
    match cmd.spawn() {
        Ok(child) => Ok(child),
        Err(err) if err.raw_os_error() == Some(740) => {
            // ERROR_ELEVATION_REQUIRED (740): invoke ShellExecute via PowerShell Start-Process so UAC can prompt.
            std::process::Command::new("powershell")
                .args([
                    "-NoProfile",
                    "-NonInteractive",
                    "-WindowStyle",
                    "Hidden",
                    "-Command",
                    "Start-Process -FilePath $env:MIJIA_INSTALLER_PATH",
                ])
                .env("MIJIA_INSTALLER_PATH", installer_path)
                .spawn()
                .map_err(|e| format!("启动安装程序失败：{e}"))
        }
        Err(err) => Err(format!("启动安装程序失败：{err}")),
    }
}

#[tauri::command]
async fn install_update(app: AppHandle, asset: InstallerAssetPayload) -> Result<(), String> {
    let asset_url = validated_release_asset_url(&asset.download_url)?;
    let lower_path = asset_url.path().to_ascii_lowercase();
    if !lower_path.ends_with(".exe") && !lower_path.ends_with(".msi") {
        return Err("更新包地址必须指向 .exe 或 .msi 安装程序".to_string());
    }
    let safe_name = sanitize_installer_filename(&asset.name)?;
    let sig_url = validated_release_asset_url(&asset.signature_url)?;
    if !sig_url.path().to_ascii_lowercase().ends_with(".ed25519.sig") {
        return Err("更新签名文件地址必须以 .ed25519.sig 结尾".to_string());
    }

    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            if attempt.previous().len() >= 5 {
                return attempt.stop();
            }
            if release_asset_redirect_allowed(attempt.url()) {
                attempt.follow()
            } else {
                attempt.stop()
            }
        }))
        .timeout(Duration::from_secs(120))
        .user_agent("MenuBarMijia-Windows")
        .build()
        .map_err(|err| format!("无法初始化下载客户端：{err}"))?;

    let expected_hex = if let Some(inline) = asset
        .sha256
        .as_deref()
        .filter(|s| !s.trim().is_empty())
    {
        parse_sha256_hex(inline).ok_or_else(|| "更新包 SHA-256 摘要格式无效".to_string())?
    } else if let Some(sidecar_raw) = asset
        .checksum_url
        .as_deref()
        .filter(|s| !s.trim().is_empty())
    {
        let sidecar_url = validated_release_asset_url(sidecar_raw)?;
        if !sidecar_url.path().to_ascii_lowercase().ends_with(".sha256") {
            return Err("校验文件地址必须以 .sha256 结尾".to_string());
        }
        let resp = client
            .get(sidecar_url)
            .send()
            .await
            .map_err(|err| format!("下载 SHA-256 校验文件失败：{err}"))?;
        if !resp.status().is_success() {
            return Err(format!("下载 SHA-256 校验文件失败（HTTP {}）", resp.status().as_u16()));
        }
        let text = resp
            .text()
            .await
            .map_err(|err| format!("读取 SHA-256 校验文件失败：{err}"))?;
        parse_sha256_hex(&text).ok_or_else(|| "无法解析 SHA-256 校验文件".to_string())?
    } else {
        return Err("缺少更新包 SHA-256 校验信息，已中止安装".to_string());
    };

    let sig_resp = client
        .get(sig_url)
        .send()
        .await
        .map_err(|err| format!("下载 Ed25519 更新签名失败：{err}"))?;
    if sig_resp.status().as_u16() == 404 {
        return Err("更新包缺少 Ed25519 数字签名（.ed25519.sig），已中止安装".to_string());
    }
    if !sig_resp.status().is_success() {
        return Err(format!(
            "下载 Ed25519 更新签名失败（HTTP {}）",
            sig_resp.status().as_u16()
        ));
    }
    let sig_text = sig_resp
        .text()
        .await
        .map_err(|err| format!("读取 Ed25519 更新签名失败：{err}"))?;

    let response = client
        .get(asset_url)
        .send()
        .await
        .map_err(|err| format!("下载更新安装包失败：{err}"))?;
    if !response.status().is_success() {
        return Err(format!("下载更新安装包失败（HTTP {}）", response.status().as_u16()));
    }
    let bytes = response
        .bytes()
        .await
        .map_err(|err| format!("读取更新安装包数据失败：{err}"))?;

    let actual_hex = compute_sha256_hex(&bytes);
    if actual_hex != expected_hex {
        return Err(format!(
            "安装包 SHA-256 校验失败（期望 {}…，实际 {}…），已中止安装",
            &expected_hex[..12],
            &actual_hex[..12]
        ));
    }

    verify_ed25519_signature(&sig_text, UPDATE_SIGNING_PUBLIC_KEY_BASE64, &bytes)?;

    sweep_stale_update_installers();
    let installer_path = std::env::temp_dir().join(format!(
        "{STAGED_INSTALLER_PREFIX}{}-{safe_name}",
        std::process::id()
    ));
    std::fs::write(&installer_path, &bytes)
        .map_err(|err| format!("写入临时安装程序失败：{err}"))?;

    let mut child = match launch_installer(&installer_path) {
        Ok(child) => child,
        Err(err) => {
            let _ = std::fs::remove_file(&installer_path);
            return Err(err);
        }
    };

    std::thread::sleep(Duration::from_millis(250));
    if let Ok(Some(status)) = child.try_wait() {
        if !status.success() {
            let _ = std::fs::remove_file(&installer_path);
            return Err(format!("安装程序未能正常启动（退出码 {:?}）", status.code()));
        }
    }

    let app_for_exit = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(150));
        app_for_exit.exit(0);
    });
    Ok(())
}

#[tauri::command]
fn set_update_available(app: AppHandle, version: Option<String>) -> Result<(), String> {
    let shortcut_label = {
        let mut guard = TRAY_AND_HOTKEY_STATE
            .write()
            .map_err(|_| "托盘状态不可用".to_string())?;
        guard.update_version = version.clone();
        guard.shortcut_label.clone()
    };
    let tray = app
        .tray_by_id("main-tray")
        .ok_or_else(|| "托盘尚未就绪".to_string())?;
    let menu = build_tray_menu(&app, shortcut_label.as_deref(), version.as_deref())
        .map_err(|error| error.to_string())?;
    tray.set_menu(Some(menu)).map_err(|error| error.to_string())
}

/// Applies the user's global shortcut preference (#43), adhering to Coding Standard #3:
/// disabling immediately unregisters the system-wide hotkey; enabling or changing unregisters
/// any previous hotkey before registering the new one and surfaces conflicts as `Err`.
#[tauri::command]
fn set_global_shortcut(app: AppHandle, enabled: bool, shortcut: String) -> Result<(), String> {
    let (old_shortcut, update_version) = {
        let guard = TRAY_AND_HOTKEY_STATE
            .read()
            .map_err(|_| "快捷键状态不可用".to_string())?;
        (guard.active_shortcut, guard.update_version.clone())
    };

    if !enabled {
        if let Some(old) = old_shortcut {
            let _ = app.global_shortcut().unregister(old);
        }
        if let Ok(mut guard) = TRAY_AND_HOTKEY_STATE.write() {
            guard.active_shortcut = None;
            guard.shortcut_label = None;
        }
        refresh_tray_chrome(&app, None, update_version.as_deref());
        return Ok(());
    }

    let (parsed, label) = parse_global_shortcut(&shortcut)?;
    if old_shortcut == Some(parsed) && app.global_shortcut().is_registered(parsed) {
        if let Ok(mut guard) = TRAY_AND_HOTKEY_STATE.write() {
            guard.shortcut_label = Some(label.clone());
        }
        refresh_tray_chrome(&app, Some(&label), update_version.as_deref());
        return Ok(());
    }

    if let Some(old) = old_shortcut {
        let _ = app.global_shortcut().unregister(old);
    }

    if let Err(err) = app.global_shortcut().register(parsed) {
        if let Ok(mut guard) = TRAY_AND_HOTKEY_STATE.write() {
            guard.active_shortcut = None;
            guard.shortcut_label = None;
        }
        refresh_tray_chrome(&app, None, update_version.as_deref());
        return Err(format!("这个组合已被其他应用占用或无法注册（{err}），换一个再试。"));
    }

    if let Ok(mut guard) = TRAY_AND_HOTKEY_STATE.write() {
        guard.active_shortcut = Some(parsed);
        guard.shortcut_label = Some(label.clone());
    }
    refresh_tray_chrome(&app, Some(&label), update_version.as_deref());
    Ok(())
}

#[derive(Serialize)]
struct NativeHttpResponse {
    status: u16,
    headers: HashMap<String, String>,
    body: String,
}

#[tauri::command]
async fn native_http(
    url: String,
    method: Option<String>,
    headers: Option<HashMap<String, String>>,
    body: Option<String>,
    follow_redirects: Option<bool>,
    timeout_ms: Option<u64>,
) -> Result<NativeHttpResponse, String> {
    let allowed_origins = allowed_origins_snapshot()?;
    let parsed_url = reqwest::Url::parse(&url).map_err(|e| format!("native_http 地址无效：{e}"))?;
    check_url_allowed(&parsed_url, &allowed_origins)?;

    let follow = follow_redirects.unwrap_or(true);
    let policy = if follow {
        let redirect_origins = allowed_origins.clone();
        let original_origin = url_origin(&parsed_url).expect("validated request origin");
        reqwest::redirect::Policy::custom(move |attempt| {
            if attempt.previous().len() >= 5 {
                return attempt.stop();
            }
            // Even another configured origin must not receive this request's headers or body.
            if redirect_allowed(&original_origin, attempt.url(), &redirect_origins) {
                attempt.follow()
            } else {
                attempt.stop()
            }
        })
    } else {
        reqwest::redirect::Policy::none()
    };

    let client = reqwest::Client::builder()
        .redirect(policy)
        .timeout(Duration::from_millis(timeout_ms.unwrap_or(15_000)))
        .build()
        .map_err(|e| e.to_string())?;

    let verb = method.unwrap_or_else(|| "GET".to_string()).to_uppercase();
    let mut req = match verb.as_str() {
        "GET" => client.get(&url),
        "POST" => client.post(&url),
        "PUT" => client.put(&url),
        "PATCH" => client.patch(&url),
        "DELETE" => client.delete(&url),
        other => return Err(format!("native_http 不支持的方法：{other}")),
    };

    if let Some(hdrs) = headers {
        let mut map = HeaderMap::new();
        for (k, v) in hdrs {
            // Request framing is owned by reqwest; letting the frontend set these
            // could smuggle a second request past the URL allowlist.
            if matches!(
                k.to_ascii_lowercase().as_str(),
                "host" | "content-length" | "transfer-encoding" | "connection" | "upgrade"
            ) {
                continue;
            }
            if let (Ok(name), Ok(val)) = (HeaderName::from_str(&k), HeaderValue::from_str(&v)) {
                map.insert(name, val);
            }
        }
        req = req.headers(map);
    }

    if let Some(b) = body {
        req = req.body(b);
    }

    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    // A stopped redirect comes back as a 3xx here; surfacing it as an error is
    // clearer than handing the frontend a response from a host it may not use.
    if follow && resp.status().is_redirection() && status != 304 {
        return Err("native_http 拒绝跨来源或未授权重定向".to_string());
    }

    let mut out_headers: HashMap<String, String> = HashMap::new();
    for (name, val) in resp.headers().iter() {
        if let Ok(v_str) = val.to_str() {
            let key = name.as_str().to_lowercase();
            out_headers
                .entry(key)
                .and_modify(|existing| {
                    existing.push_str("; ");
                    existing.push_str(v_str);
                })
                .or_insert_with(|| v_str.to_string());
        }
    }

    let text = resp.text().await.map_err(|e| e.to_string())?;
    Ok(NativeHttpResponse {
        status,
        headers: out_headers,
        body: text,
    })
}

#[tauri::command]
fn set_allowed_origins(_origins: Vec<String>) -> Result<(), String> {
    Err("前端不能自行授权网络来源".into())
}

fn origin_from_endpoint(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let with_scheme = if trimmed.contains("://") {
        trimmed.to_string()
    } else {
        format!("https://{trimmed}")
    };
    let url = reqwest::Url::parse(&with_scheme).ok()?;
    url_origin(&url)
}

fn requested_service_origins(assistant_url: &str, ha_url: &str) -> Result<HashSet<String>, String> {
    let mut origins = HashSet::new();
    for raw in [assistant_url, ha_url] {
        if raw.trim().is_empty() {
            continue;
        }
        let origin = origin_from_endpoint(raw)
            .ok_or_else(|| format!("invalid configured endpoint: {raw}"))?;
        origins.insert(origin);
    }
    Ok(origins)
}

fn read_origin_store(path: &std::path::Path) -> HashSet<String> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return HashSet::new();
    };
    let Ok(values) = serde_json::from_str::<Vec<String>>(&text) else {
        return HashSet::new();
    };
    values
        .into_iter()
        .filter_map(|value| normalize_extra_origin(&value))
        .collect()
}

fn write_origin_store(path: &std::path::Path, origins: &HashSet<String>) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| format!("无法保存已授权来源：{error}"))?;
    }
    let mut values: Vec<&String> = origins.iter().collect();
    values.sort();
    let body = serde_json::to_string(&values).map_err(|error| error.to_string())?;
    std::fs::write(path, body).map_err(|error| format!("无法保存已授权来源：{error}"))
}

#[cfg(test)]
fn authorization_store_path() -> Option<std::path::PathBuf> {
    None
}

#[cfg(not(test))]
fn authorization_store_path() -> Option<std::path::PathBuf> {
    let base = std::env::var_os("APPDATA")?;
    Some(std::path::PathBuf::from(base).join("MenuBarMijia").join("authorized-http-origins.json"))
}

fn store_authorized(origins: &HashSet<String>) -> Result<(), String> {
    if let Some(path) = authorization_store_path() {
        write_origin_store(&path, origins)?;
    }
    let mut guard = EXTRA_ALLOWED_ORIGINS
        .write()
        .map_err(|_| "origin allowlist unavailable".to_string())?;
    *guard = origins.clone();
    Ok(())
}

fn decide_service_origins(
    current: &HashSet<String>,
    assistant_url: &str,
    ha_url: &str,
    confirm: impl Fn(&str) -> bool,
) -> Result<HashSet<String>, String> {
    let requested = requested_service_origins(assistant_url, ha_url)?;
    let mut novel: Vec<String> = requested.difference(current).cloned().collect();
    novel.sort();
    for origin in &novel {
        if !confirm(origin) {
            return Err(format!("未授权的网络来源：{origin}"));
        }
    }
    Ok(requested)
}

fn authorize_service_endpoints(
    assistant_url: &str,
    ha_url: &str,
    confirm: impl Fn(&str) -> bool,
) -> Result<(), String> {
    let current = allowed_origins_snapshot()?;
    let next = decide_service_origins(&current, assistant_url, ha_url, confirm)?;
    store_authorized(&next)
}

#[cfg(test)]
fn user_confirms_origin(_origin: &str) -> bool {
    false
}

#[cfg(all(windows, not(test)))]
fn user_confirms_origin(origin: &str) -> bool {
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;
    let text = format!(
        "允许 MenuBarMijia 连接这个地址吗？\n\n{origin}\n\n只有你在设置里填写的 Home Assistant 或 AI 服务地址才应该出现在这里。"
    );
    let text_wide: Vec<u16> = OsStr::new(&text).encode_wide().chain(std::iter::once(0)).collect();
    let title_wide: Vec<u16> = OsStr::new("MenuBarMijia").encode_wide().chain(std::iter::once(0)).collect();
    #[link(name = "user32")]
    extern "system" {
        fn MessageBoxW(
            hwnd: *mut std::ffi::c_void,
            text: *const u16,
            caption: *const u16,
            utype: u32,
        ) -> i32;
    }
    const MB_YESNO: u32 = 0x0000_0004;
    const MB_ICONWARNING: u32 = 0x0000_0030;
    const MB_DEFBUTTON2: u32 = 0x0000_0100;
    const IDYES: i32 = 6;
    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            text_wide.as_ptr(),
            title_wide.as_ptr(),
            MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2,
        ) == IDYES
    }
}

#[cfg(all(not(windows), not(test)))]
fn user_confirms_origin(_origin: &str) -> bool {
    false
}

#[tauri::command]
fn set_service_endpoints(assistant_url: String, ha_url: String) -> Result<(), String> {
    authorize_service_endpoints(&assistant_url, &ha_url, user_confirms_origin)
}

#[tauri::command]
fn secure_store_get(name: String) -> Result<Option<String>, String> {
    let entry = credential_entry(&name)?;
    match entry.get_password() {
        Ok(value) => Ok(Some(value)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(error) => Err(format!("读取 Windows 凭据失败：{error}")),
    }
}

#[tauri::command]
fn secure_store_set(name: String, value: String) -> Result<(), String> {
    if value.is_empty() {
        return secure_store_delete(name);
    }
    let entry = credential_entry(&name)?;
    entry
        .set_password(&value)
        .map_err(|error| format!("写入 Windows 凭据失败：{error}"))
}

#[tauri::command]
fn secure_store_delete(name: String) -> Result<(), String> {
    let entry = credential_entry(&name)?;
    match entry.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(error) => Err(format!("删除 Windows 凭据失败：{error}")),
    }
}

#[tauri::command]
fn hide_panel(app: AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.hide();
    }
}

#[tauri::command]
fn quit_app(app: AppHandle) {
    app.exit(0);
}

#[tauri::command]
fn set_pin_popover(pin: bool) {
    PIN_POPOVER.store(pin, Ordering::SeqCst);
}

/// Resizes the popover to the chosen panel height (0 = fill the screen above the taskbar),
/// keeping its bottom edge where it was so it stays anchored to the tray.
#[tauri::command]
fn set_panel_height(app: AppHandle, height: f64) {
    let Some(window) = app.get_webview_window("main") else { return };
    let monitor = window.current_monitor().ok().flatten().or_else(|| window.primary_monitor().ok().flatten());
    let scale = monitor.as_ref().map(|m| m.scale_factor()).unwrap_or(1.0);
    let screen_h = monitor.as_ref().map(|m| m.size().height as f64 / scale).unwrap_or(900.0);
    let max_h = (screen_h - 54.0 - 24.0).max(480.0);
    let target = if height <= 0.0 { max_h } else { height.min(max_h) };

    let old_pos = window.outer_position().unwrap_or(PhysicalPosition::new(0, 0));
    let old_size = window.outer_size().unwrap_or(PhysicalSize::new(480, 520));
    let width = old_size.width as f64 / scale;
    let _ = window.set_size(tauri::LogicalSize::new(width, target));
    let new_h = (target * scale) as i32;
    let top = monitor.as_ref().map(|m| m.position().y).unwrap_or(0) + (12.0 * scale) as i32;
    let y = (old_pos.y + old_size.height as i32 - new_h).max(top);
    let _ = window.set_position(PhysicalPosition::new(old_pos.x, y));
}

fn position_popover(window: &WebviewWindow, anchor: Option<PhysicalPosition<f64>>) {
    let win_size = window.outer_size().unwrap_or(PhysicalSize::new(480, 520));
    let win_w = win_size.width as i32;
    let win_h = win_size.height as i32;

    let monitor = window
        .current_monitor()
        .ok()
        .flatten()
        .or_else(|| window.primary_monitor().ok().flatten());

    if let Some(mon) = monitor {
        let mon_pos = mon.position();
        let mon_size = mon.size();
        let scale = mon.scale_factor();
        let margin = (12.0 * scale) as i32;
        let taskbar_offset = (54.0 * scale) as i32;

        let min_x = mon_pos.x + margin;
        let max_x = (mon_pos.x + mon_size.width as i32 - win_w - margin).max(min_x);
        let min_y = mon_pos.y + margin;
        let max_y = (mon_pos.y + mon_size.height as i32 - win_h - taskbar_offset).max(min_y);

        if let Some(pos) = anchor {
            let target_x = (pos.x as i32 - win_w / 2).clamp(min_x, max_x);
            let above_tray_y = pos.y as i32 - win_h - margin;
            let target_y = if above_tray_y >= min_y {
                above_tray_y.min(max_y)
            } else {
                max_y
            };
            let _ = window.set_position(PhysicalPosition::new(target_x, target_y));
        } else {
            let _ = window.set_position(PhysicalPosition::new(max_x, max_y));
        }
    } else if let Some(pos) = anchor {
        let x = (pos.x as i32 - win_w / 2).max(16);
        let y = (pos.y as i32 - win_h - 16).max(16);
        let _ = window.set_position(PhysicalPosition::new(x, y));
    }
}

fn toggle_main_window(app: &AppHandle, anchor: Option<PhysicalPosition<f64>>, from_tray_click: bool) {
    if let Some(window) = app.get_webview_window("main") {
        let is_visible = window.is_visible().unwrap_or(false);
        if is_visible {
            let _ = window.hide();
        } else {
            if from_tray_click {
                let elapsed = now_epoch_ms().saturating_sub(LAST_FOCUS_LOSS_MS.load(Ordering::SeqCst));
                if elapsed < 280 {
                    return;
                }
            }
            position_popover(&window, anchor);
            let _ = window.show();
            let _ = window.set_focus();
        }
    }
}

fn main() {
    let default_shortcut = Shortcut::new(Some(Modifiers::ALT), Code::KeyM);
    if let Ok(mut guard) = TRAY_AND_HOTKEY_STATE.write() {
        guard.active_shortcut = Some(default_shortcut);
        guard.shortcut_label = Some("Alt+M".to_string());
    }

    tauri::Builder::default()
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(move |app, shortcut, event| {
                    if event.state() != ShortcutState::Pressed {
                        return;
                    }
                    let matches = TRAY_AND_HOTKEY_STATE
                        .read()
                        .ok()
                        .and_then(|guard| guard.active_shortcut)
                        .is_some_and(|active| &active == shortcut);
                    if matches {
                        toggle_main_window(app, None, false);
                    }
                })
                .build(),
        )
        .invoke_handler(tauri::generate_handler![
            native_http,
            set_allowed_origins,
            set_service_endpoints,
            secure_store_get,
            secure_store_set,
            secure_store_delete,
            hide_panel,
            quit_app,
            set_panel_height,
            set_pin_popover,
            set_update_available,
            set_global_shortcut,
            open_release_page,
            install_update
        ])
        .setup(move |app| {
            sweep_stale_update_installers();
            if let Some(path) = authorization_store_path() {
                if let Ok(mut guard) = EXTRA_ALLOWED_ORIGINS.write() {
                    *guard = read_origin_store(&path);
                }
            }
            let _ = app.global_shortcut().register(default_shortcut);
            if let Some(main_win) = app.get_webview_window("main") {
                position_popover(&main_win, None);
                let win_for_event = main_win.clone();
                main_win.on_window_event(move |event| {
                    if let WindowEvent::Focused(false) = event {
                        if !PIN_POPOVER.load(Ordering::SeqCst) {
                            LAST_FOCUS_LOSS_MS.store(now_epoch_ms(), Ordering::SeqCst);
                            let _ = win_for_event.hide();
                        }
                    }
                });
            }

            let menu = build_tray_menu(app.handle(), Some("Alt+M"), None)?;

            let mut tray_builder = TrayIconBuilder::with_id("main-tray")
                .tooltip("MenuBarMijia · 菜单栏米家 (Alt+M)")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "toggle" => toggle_main_window(app, None, false),
                    "update" => {
                        if let Some(window) = app.get_webview_window("main") {
                            PIN_POPOVER.store(true, Ordering::SeqCst);
                            position_popover(&window, None);
                            let _ = window.show();
                            let _ = window.set_focus();
                            let _ = window.eval(
                                "window.dispatchEvent(new CustomEvent('menumijia:open-update'))",
                            );
                        } else if let Ok(url) = validated_release_url(RELEASE_PAGE_URL) {
                            open_url_in_browser(&url);
                        }
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        position,
                        ..
                    } = event
                    {
                        toggle_main_window(tray.app_handle(), Some(position), true);
                    }
                });

            if let Some(icon) = app.default_window_icon() {
                tray_builder = tray_builder.icon(icon.clone());
            }

            let _tray = tray_builder.build(app)?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running MenuBarMijia Windows application");
}

#[cfg(test)]
mod tests {
    use super::*;



    fn extra(origins: &[&str]) -> HashSet<String> {
        origins
            .iter()
            .filter_map(|origin| normalize_extra_origin(origin))
            .collect()
    }

    fn allows(url: &str, origins: &[&str]) -> bool {
        let parsed = reqwest::Url::parse(url).expect("test URL");
        check_url_allowed(&parsed, &extra(origins)).is_ok()
    }

    #[test]
    fn native_http_invoke_rejects_an_unconfigured_host() {
        let app = tauri::test::mock_builder()
            .invoke_handler(tauri::generate_handler![native_http])
            .build(tauri::test::mock_context(tauri::test::noop_assets()))
            .expect("isolated IPC application");
        let window = tauri::WebviewWindowBuilder::new(&app, "main", Default::default())
            .build()
            .expect("isolated IPC window");
        let response = tauri::test::get_ipc_response(
            &window,
            tauri::webview::InvokeRequest {
                cmd: "native_http".into(),
                callback: tauri::ipc::CallbackFn(0),
                error: tauri::ipc::CallbackFn(1),
                url: "http://tauri.localhost".parse().expect("local app origin"),
                body: tauri::ipc::InvokeBody::Json(serde_json::json!({
                    "url": "https://not-configured.invalid/private",
                    "method": "POST",
                    "headers": {"Authorization": "Bearer isolated-test-value"},
                    "body": "private-data",
                    "timeoutMs": 100
                })),
                headers: Default::default(),
                invoke_key: tauri::test::INVOKE_KEY.to_string(),
            },
        );
        let error = response.expect_err("unconfigured hosts must fail before networking");
        let message = error.as_str().expect("policy error returned to the frontend");
        assert!(message.contains("not-configured.invalid"), "unexpected IPC error: {message}");
        assert!(message.contains("拒绝访问未授权来源"), "request reached transport: {message}");
    }

    #[test]
    fn allows_only_xiaomi_api_and_configured_origins() {
        assert!(allows("https://api.io.mi.com/app/home/device_list", &[]));
        assert!(allows("https://de.api.io.mi.com/app/home/device_list", &[]));
        assert!(allows(
            "https://account.xiaomi.com/longPolling/loginUrl",
            &[]
        ));
        assert!(allows("https://lp.account.xiaomi.com/lp/s?d=x", &[]));
        assert!(allows("https://miot-spec.org/miot-spec-v2/instance", &[]));
        assert!(allows(
            "https://api.deepseek.com/v1/chat/completions",
            &["https://api.deepseek.com"]
        ));
        assert!(allows("http://192.168.1.8:8123/api/", &["http://192.168.1.8:8123"]));

        assert!(!allows("https://evil.example/steal", &[]));
        assert!(!allows("https://api.io.mi.com.evil.example/app", &[]));
        assert!(!allows(
            "https://api.deepseek.com.evil.example/v1",
            &["https://api.deepseek.com"]
        ));
        assert!(!allows("file:///C:/Windows/win.ini", &[]));
    }

    #[test]
    fn built_in_services_reject_plaintext_and_alternate_ports() {
        assert!(!allows("http://api.io.mi.com/app/private", &[]));
        assert!(!allows("https://api.io.mi.com:8443/app/private", &[]));
        assert!(!allows("http://account.xiaomi.com/pass/serviceLogin", &[]));
        assert!(!allows("http://api.io.mi.com/app/private", &["http://api.io.mi.com"]));
        assert!(!allows("https://api.io.mi.com:8443/app/private", &["https://api.io.mi.com:8443"]));
    }

    #[test]
    fn configured_origins_keep_scheme_and_effective_port() {
        assert!(allows("https://api.deepseek.com/v1", &["https://api.deepseek.com:443"]));
        assert!(!allows("http://api.deepseek.com/v1", &["https://api.deepseek.com"]));
        assert!(!allows("https://api.deepseek.com:8443/v1", &["https://api.deepseek.com"]));
        assert!(allows("http://localhost:11434/api", &["http://localhost:11434"]));
        assert!(!allows("http://localhost:8123/api", &["http://localhost:11434"]));
        assert!(allows("http://[::1]:11434/api", &["http://[::1]:11434"]));
        assert!(!allows("https://user@api.io.mi.com/app", &[]));
    }

    #[test]
    fn normalizes_configured_origins_and_rejects_non_origins() {
        assert_eq!(normalize_extra_origin(" HTTPS://API.DeepSeek.com.:443/ "), Some("https://api.deepseek.com:443".to_string()));
        assert_eq!(normalize_extra_origin("http://[::1]:11434"), Some("http://[::1]:11434".to_string()));
        for invalid in ["api.deepseek.com", "https://evil.example/path", "https://evil.example?key=value", "https://evil.example#fragment", "https://user@evil.example", "file:///tmp/config", ""] {
            assert_eq!(normalize_extra_origin(invalid), None, "{invalid}");
        }
    }

    #[test]
    fn redirects_cannot_change_origin_even_to_another_allowed_origin() {
        let origins = extra(&["https://configured.example", "http://configured.example", "https://configured.example:8443"]);
        let original = reqwest::Url::parse("https://configured.example/start").unwrap();
        let original_origin = url_origin(&original).unwrap();
        assert!(redirect_allowed(&original_origin, &reqwest::Url::parse("https://configured.example:443/next").unwrap(), &origins));
        for target in ["http://configured.example/next", "https://configured.example:8443/next", "https://api.io.mi.com/app"] {
            assert!(!redirect_allowed(&original_origin, &reqwest::Url::parse(target).unwrap(), &origins), "{target}");
        }
    }

    #[test]
    fn credential_names_are_limited_to_known_entries() {
        assert_eq!(
            allowed_credential_name("mi_session").ok(),
            Some("mi_session")
        );
        assert_eq!(allowed_credential_name("ha_token").ok(), Some("ha_token"));
        assert_eq!(
            allowed_credential_name("assistant_api_key").ok(),
            Some("assistant_api_key")
        );
        assert_eq!(
            allowed_credential_name("assistant_api_key_openrouter").ok(),
            Some("assistant_api_key_openrouter")
        );
        assert!(allowed_credential_name("arbitrary_key").is_err());
        assert!(allowed_credential_name("assistant_api_key_").is_err());
        assert!(allowed_credential_name("assistant_api_key_a/b").is_err());
    }

    #[test]
    fn allows_the_public_github_release_api_only() {
        assert!(allows(
            "https://api.github.com/repos/jryang1997/MenuBarMijia/releases/latest",
            &[]
        ));
        // The browser-facing host is opened through the OS, never proxied by native_http.
        assert!(!allows("https://github.com/jryang1997/MenuBarMijia/releases", &[]));
        assert!(!allows("https://api.github.com.evil.example/latest", &[]));
    }

    #[test]
    fn only_opens_menu_barmijia_release_pages() {
        assert!(validated_release_url(RELEASE_PAGE_URL).is_ok());
        assert!(validated_release_url(
            "https://github.com/jryang1997/MenuBarMijia/releases/tag/v1.0.7"
        )
        .is_ok());

        assert!(validated_release_url("http://github.com/jryang1997/MenuBarMijia/releases").is_err());
        assert!(validated_release_url("https://evil.example/jryang1997/MenuBarMijia/releases").is_err());
        assert!(validated_release_url("https://github.com/other/repo/releases").is_err());
        assert!(validated_release_url("https://github.com/jryang1997/MenuBarMijia").is_err());
        assert!(validated_release_url("javascript:alert(1)").is_err());
    }

    #[test]
    fn frontend_cannot_grant_an_arbitrary_origin_and_then_request_it() {
        {
            let mut guard = EXTRA_ALLOWED_ORIGINS.write().expect("allowlist lock");
            guard.clear();
        }
        let app = tauri::test::mock_builder()
            .invoke_handler(tauri::generate_handler![native_http, set_allowed_origins, set_service_endpoints])
            .build(tauri::test::mock_context(tauri::test::noop_assets()))
            .expect("isolated IPC application");
        let window = tauri::WebviewWindowBuilder::new(&app, "main", Default::default())
            .build()
            .expect("isolated IPC window");
        let invoke_url: reqwest::Url = "http://tauri.localhost".parse().expect("local app origin");
        let _grant = tauri::test::get_ipc_response(
            &window,
            tauri::webview::InvokeRequest {
                cmd: "set_allowed_origins".into(),
                callback: tauri::ipc::CallbackFn(0),
                error: tauri::ipc::CallbackFn(1),
                url: invoke_url.clone(),
                body: tauri::ipc::InvokeBody::Json(serde_json::json!({
                    "origins": ["https://evil.example"]
                })),
                headers: Default::default(),
                invoke_key: tauri::test::INVOKE_KEY.to_string(),
            },
        );
        let _service = tauri::test::get_ipc_response(
            &window,
            tauri::webview::InvokeRequest {
                cmd: "set_service_endpoints".into(),
                callback: tauri::ipc::CallbackFn(0),
                error: tauri::ipc::CallbackFn(1),
                url: invoke_url.clone(),
                body: tauri::ipc::InvokeBody::Json(serde_json::json!({
                    "assistantUrl": "https://evil.example",
                    "haUrl": ""
                })),
                headers: Default::default(),
                invoke_key: tauri::test::INVOKE_KEY.to_string(),
            },
        );
        let response = tauri::test::get_ipc_response(
            &window,
            tauri::webview::InvokeRequest {
                cmd: "native_http".into(),
                callback: tauri::ipc::CallbackFn(0),
                error: tauri::ipc::CallbackFn(1),
                url: invoke_url,
                body: tauri::ipc::InvokeBody::Json(serde_json::json!({
                    "url": "https://evil.example/steal",
                    "method": "POST",
                    "headers": {"Authorization": "Bearer isolated-test-value"},
                    "body": "private-data",
                    "timeoutMs": 100
                })),
                headers: Default::default(),
                invoke_key: tauri::test::INVOKE_KEY.to_string(),
            },
        );
        EXTRA_ALLOWED_ORIGINS.write().expect("allowlist lock").clear();
        let error = response.expect_err("a frontend grant must not make native_http reach evil.example");
        let message = error.as_str().expect("policy error returned to the frontend");
        assert!(
            message.contains("拒绝访问未授权来源"),
            "frontend grant reached transport: {message}"
        );
        assert!(message.contains("evil.example"), "unexpected IPC error: {message}");
    }

    #[test]
    fn confirmation_authorizes_only_the_configured_service_origins() {
        let empty = HashSet::new();
        let granted = decide_service_origins(
            &empty,
            "HTTPS://API.DeepSeek.com:8443/v1",
            "http://[::1]:8123/api",
            |_| true,
        )
        .expect("confirmed endpoints authorize");
        assert!(check_url_allowed(
            &reqwest::Url::parse("https://api.deepseek.com:8443/v1/chat/completions").unwrap(),
            &granted
        )
        .is_ok());
        assert!(check_url_allowed(
            &reqwest::Url::parse("http://[::1]:8123/api/states").unwrap(),
            &granted
        )
        .is_ok());
        assert!(check_url_allowed(
            &reqwest::Url::parse("https://evil.example/steal").unwrap(),
            &granted
        )
        .is_err());
        assert!(check_url_allowed(
            &reqwest::Url::parse("http://api.deepseek.com:8443/v1").unwrap(),
            &granted
        )
        .is_err());

        let denied = decide_service_origins(&granted, "https://evil.example", "http://[::1]:8123/api", |_| false);
        assert!(denied.is_err());
        assert!(check_url_allowed(
            &reqwest::Url::parse("https://evil.example/steal").unwrap(),
            &granted
        )
        .is_err());

        let shrunk = decide_service_origins(&granted, "", "http://[::1]:8123/api", |_| false)
            .expect("dropping an endpoint does not need a new grant");
        assert!(check_url_allowed(
            &reqwest::Url::parse("https://api.deepseek.com:8443/v1").unwrap(),
            &shrunk
        )
        .is_err());
        assert!(check_url_allowed(
            &reqwest::Url::parse("http://[::1]:8123/api/states").unwrap(),
            &shrunk
        )
        .is_ok());
    }

    #[test]
    fn authorized_origin_store_roundtrips_exact_origins() {
        let dir = std::env::temp_dir().join(format!("menubarmijia-origins-{}", std::process::id()));
        let path = dir.join("authorized-http-origins.json");
        let mut origins = HashSet::new();
        origins.insert("https://api.deepseek.com:8443".to_string());
        origins.insert("http://[::1]:8123".to_string());
        write_origin_store(&path, &origins).expect("write store");
        assert_eq!(read_origin_store(&path), origins);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn global_shortcut_parser_accepts_modified_keys_and_function_keys_only() {
        let (alt_m, label) = parse_global_shortcut("Alt+M").expect("Alt+M is valid");
        assert_eq!(label, "Alt+M");
        assert_eq!(alt_m, Shortcut::new(Some(Modifiers::ALT), Code::KeyM));

        let (ctrl_shift_k, _) = parse_global_shortcut("Ctrl+Shift+K").expect("Ctrl+Shift+K is valid");
        assert_eq!(
            ctrl_shift_k,
            Shortcut::new(Some(Modifiers::CONTROL | Modifiers::SHIFT), Code::KeyK)
        );

        let (f8, _) = parse_global_shortcut("F8").expect("standalone F8 is valid");
        assert_eq!(f8, Shortcut::new(None, Code::F8));

        let (ctrl_numpad1, _) = parse_global_shortcut("Ctrl+Numpad1").expect("Ctrl+Numpad1 is valid");
        assert_eq!(ctrl_numpad1, Shortcut::new(Some(Modifiers::CONTROL), Code::Numpad1));

        for invalid in ["", "   ", "M", "1", "Space", "Ctrl+", "NotAKey"] {
            assert!(
                parse_global_shortcut(invalid).is_err(),
                "expected {invalid:?} to be rejected"
            );
        }
    }

    #[test]
    fn tray_labels_include_shortcut_only_when_enabled() {
        assert_eq!(
            tray_labels_for_shortcut(Some("Ctrl+Alt+M")),
            (
                "打开/隐藏控制中心 (Ctrl+Alt+M)".to_string(),
                "MenuBarMijia · 菜单栏米家 (Ctrl+Alt+M)".to_string()
            )
        );
        assert_eq!(
            tray_labels_for_shortcut(None),
            (
                "打开/隐藏控制中心".to_string(),
                "MenuBarMijia · 菜单栏米家".to_string()
            )
        );
    }

    #[test]
    fn validates_release_asset_urls_filenames_and_sha256() {
        assert!(validated_release_asset_url(
            "https://github.com/jryang1997/MenuBarMijia/releases/download/v1.1.4/MenuBarMijia-1.1.4-windows-x64-setup.exe"
        )
        .is_ok());
        assert!(validated_release_asset_url(
            "https://github.com/jryang1997/MenuBarMijia/releases/download/v1.1.4/MenuBarMijia-1.1.4-windows-x64-setup.exe.sha256"
        )
        .is_ok());

        for bad in [
            "http://github.com/jryang1997/MenuBarMijia/releases/download/v1.1.4/setup.exe",
            "https://evil.example/jryang1997/MenuBarMijia/releases/download/v1.1.4/setup.exe",
            "https://github.com/other/repo/releases/download/v1.1.4/setup.exe",
            "https://github.com/jryang1997/MenuBarMijia/releases/tag/v1.1.4",
            "https://github.com/jryang1997/MenuBarMijia/releases/download/v1.1.4/setup.exe?foo=1",
        ] {
            assert!(validated_release_asset_url(bad).is_err(), "{bad}");
        }

        assert!(release_asset_redirect_allowed(
            &reqwest::Url::parse("https://objects.githubusercontent.com/github-production-release-asset/123").unwrap()
        ));
        assert!(!release_asset_redirect_allowed(
            &reqwest::Url::parse("https://evil.example/setup.exe").unwrap()
        ));
        assert!(!release_asset_redirect_allowed(
            &reqwest::Url::parse("http://objects.githubusercontent.com/setup.exe").unwrap()
        ));

        assert_eq!(
            sanitize_installer_filename("MenuBarMijia-1.1.4-windows-x64-setup.exe").ok(),
            Some("MenuBarMijia-1.1.4-windows-x64-setup.exe".to_string())
        );
        for bad_name in [
            "../setup.exe",
            "dir/setup.exe",
            "dir\\setup.exe",
            "C:setup.exe",
            "payload.bat",
            "",
        ] {
            assert!(sanitize_installer_filename(bad_name).is_err(), "{bad_name}");
        }

        let hex = compute_sha256_hex(b"verified-windows-installer");
        assert_eq!(parse_sha256_hex(&format!("sha256:{}", hex.to_uppercase())), Some(hex.clone()));
        assert_eq!(parse_sha256_hex(&format!("{hex}  MenuBarMijia-1.1.4-windows-x64-setup.exe\n")), Some(hex));
        assert_eq!(parse_sha256_hex("sha256:1234"), None);

        // Built-in Ed25519 public key decodes to 32 bytes (ADR-0005).
        assert_eq!(
            decode_base64_strict(UPDATE_SIGNING_PUBLIC_KEY_BASE64).map(|b| b.len()),
            Some(32)
        );
        // Cross-platform CryptoKit Ed25519 signature over `b"verified-windows-installer"`.
        let test_pub_b64 = "IVL40Zt5HSRFMkLhXy6rbLfP+ntqXtMAl5YOBpiB2xI=";
        let test_sig_b64 =
            "KtT4QT0xAahlehckpgTkX9/sMX/HypxQGInJ5/dR9Nl78X8bKzLcRNNLEzDGH6y+W3CRzkGiuf1qgIs6DCQDAQ==";
        assert!(verify_ed25519_signature(
            test_sig_b64,
            test_pub_b64,
            b"verified-windows-installer"
        )
        .is_ok());
        assert!(verify_ed25519_signature(
            test_sig_b64,
            test_pub_b64,
            b"tampered-windows-installer"
        )
        .is_err());
        assert!(verify_ed25519_signature(
            test_sig_b64,
            UPDATE_SIGNING_PUBLIC_KEY_BASE64,
            b"verified-windows-installer"
        )
        .is_err());
        assert!(verify_ed25519_signature("", UPDATE_SIGNING_PUBLIC_KEY_BASE64, b"payload").is_err());
        assert!(verify_ed25519_signature("not-base64!", UPDATE_SIGNING_PUBLIC_KEY_BASE64, b"payload").is_err());
    }
}
