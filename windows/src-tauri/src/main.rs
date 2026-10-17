#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use serde::Serialize;
use std::collections::HashMap;
use std::str::FromStr;
use std::time::Duration;
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Manager, PhysicalPosition,
};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};

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
    let policy = if follow_redirects.unwrap_or(true) {
        reqwest::redirect::Policy::limited(5)
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
        "POST" => client.post(&url),
        "PUT" => client.put(&url),
        "DELETE" => client.delete(&url),
        _ => client.get(&url),
    };

    if let Some(hdrs) = headers {
        let mut map = HeaderMap::new();
        for (k, v) in hdrs {
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

fn toggle_main_window(app: &AppHandle, anchor: Option<PhysicalPosition<f64>>) {
    if let Some(window) = app.get_webview_window("main") {
        let is_visible = window.is_visible().unwrap_or(false);
        if is_visible {
            let _ = window.hide();
        } else {
            if let Some(pos) = anchor {
                let x = (pos.x as i32 - 190).max(16);
                let y = (pos.y as i32 - 620).max(16);
                let _ = window.set_position(PhysicalPosition::new(x, y));
            }
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
                        toggle_main_window(app, None);
                    }
                })
                .build(),
        )
        .invoke_handler(tauri::generate_handler![native_http])
        .setup(move |app| {
            let _ = app.global_shortcut().register(alt_m);

            let toggle_item =
                MenuItem::with_id(app, "toggle", "显示/隐藏面板 (Alt+M)", true, None::<&str>)?;
            let quit_item = MenuItem::with_id(app, "quit", "退出 MenuMijia", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&toggle_item, &quit_item])?;

            let mut tray_builder = TrayIconBuilder::with_id("main-tray")
                .tooltip("MenuMijia · 菜单栏米家 (Alt+M)")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "toggle" => toggle_main_window(app, None),
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
                        toggle_main_window(tray.app_handle(), Some(position));
                    }
                });

            if let Some(icon) = app.default_window_icon() {
                tray_builder = tray_builder.icon(icon.clone());
            }

            let _tray = tray_builder.build(app)?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running MenuMijia Windows application");
}
