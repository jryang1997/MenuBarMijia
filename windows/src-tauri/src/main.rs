#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use serde::Serialize;
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

/// Rebuilds the tray menu, adding the "有新版本" entry only when a release is known (#39).
fn build_tray_menu(app: &AppHandle, update_version: Option<&str>) -> tauri::Result<Menu<tauri::Wry>> {
    let mut builder = MenuBuilder::new(app).text("toggle", "打开/隐藏控制中心 (Alt+M)");
    if let Some(version) = update_version {
        builder = builder.text("update", format!("有新版本 v{version}，点击查看"));
    }
    builder.text("quit", "退出 MenuBarMijia").build()
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

#[tauri::command]
fn set_update_available(app: AppHandle, version: Option<String>) -> Result<(), String> {
    let tray = app
        .tray_by_id("main-tray")
        .ok_or_else(|| "托盘尚未就绪".to_string())?;
    let menu = build_tray_menu(&app, version.as_deref()).map_err(|error| error.to_string())?;
    tray.set_menu(Some(menu)).map_err(|error| error.to_string())
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
fn set_allowed_origins(origins: Vec<String>) -> Result<(), String> {
    if origins.len() > 64 {
        return Err("origin allowlist too long".to_string());
    }
    let normalized: HashSet<String> = origins
        .iter()
        .map(|origin| normalize_extra_origin(origin).ok_or_else(|| "invalid configured origin".to_string()))
        .collect::<Result<_, _>>()?;
    let mut guard = EXTRA_ALLOWED_ORIGINS
        .write()
        .map_err(|_| "origin allowlist unavailable".to_string())?;
    *guard = normalized;
    Ok(())
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
    let old_size = window.outer_size().unwrap_or(PhysicalSize::new(360, 520));
    let width = old_size.width as f64 / scale;
    let _ = window.set_size(tauri::LogicalSize::new(width, target));
    let new_h = (target * scale) as i32;
    let top = monitor.as_ref().map(|m| m.position().y).unwrap_or(0) + (12.0 * scale) as i32;
    let y = (old_pos.y + old_size.height as i32 - new_h).max(top);
    let _ = window.set_position(PhysicalPosition::new(old_pos.x, y));
}

fn position_popover(window: &WebviewWindow, anchor: Option<PhysicalPosition<f64>>) {
    let win_size = window.outer_size().unwrap_or(PhysicalSize::new(360, 520));
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
    let alt_m = Shortcut::new(Some(Modifiers::ALT), Code::KeyM);

    tauri::Builder::default()
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(move |app, shortcut, event| {
                    if shortcut == &alt_m && event.state() == ShortcutState::Pressed {
                        toggle_main_window(app, None, false);
                    }
                })
                .build(),
        )
        .invoke_handler(tauri::generate_handler![
            native_http,
            set_allowed_origins,
            secure_store_get,
            secure_store_set,
            secure_store_delete,
            hide_panel,
            quit_app,
            set_panel_height,
            set_pin_popover,
            set_update_available,
            open_release_page
        ])
        .setup(move |app| {
            let _ = app.global_shortcut().register(alt_m);

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

            let menu = build_tray_menu(app.handle(), None)?;

            let mut tray_builder = TrayIconBuilder::with_id("main-tray")
                .tooltip("MenuBarMijia · 菜单栏米家 (Alt+M)")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "toggle" => toggle_main_window(app, None, false),
                    "update" => {
                        if let Ok(url) = validated_release_url(RELEASE_PAGE_URL) {
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
}
