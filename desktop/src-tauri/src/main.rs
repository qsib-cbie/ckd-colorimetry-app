mod engine;

use engine::{download_kind, download_name, Engine};
use std::{path::PathBuf, sync::atomic::Ordering};
use tauri::{Emitter, Manager};

#[tauri::command]
async fn pick_path(kind: String) -> Result<Option<String>, String> {
    let dialog = rfd::AsyncFileDialog::new();
    let selected = match kind.as_str() {
        "folder" => {
            dialog
                .set_title("Open CKD workspace folder")
                .pick_folder()
                .await
        }
        "import" => {
            dialog
                .set_title("Import a CKD export ZIP")
                .add_filter("CKD export ZIP", &["zip"])
                .pick_file()
                .await
        }
        _ => return Err("Unknown file dialog".into()),
    };
    Ok(selected.map(|file| file.path().to_string_lossy().into_owned()))
}

#[tauri::command]
async fn reveal_path(app: tauri::AppHandle, path: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || {
        let selected = app.state::<Engine>().workspace_path(&PathBuf::from(path))?;
        let status = std::process::Command::new("/usr/bin/open")
            .args(["-a", "Finder"])
            .arg(selected)
            .status()
            .map_err(|e| e.to_string())?;
        if !status.success() {
            return Err("Finder could not open this folder".into());
        }
        Ok(())
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn save_download(
    app: tauri::AppHandle,
    path: String,
    name: Option<String>,
) -> Result<(), String> {
    let kind = download_kind(&path)?.to_owned();
    let name = if kind == "original" {
        let handle = app.clone();
        let document_path = path
            .strip_suffix("/original")
            .ok_or("Invalid original image path")?
            .to_owned();
        tauri::async_runtime::spawn_blocking(move || -> Result<String, String> {
            let document: serde_json::Value = handle
                .state::<Engine>()
                .get(&document_path)?
                .json()
                .map_err(|e| e.to_string())?;
            Ok(document["source"]["filename"]
                .as_str()
                .ok_or("Original filename is missing")?
                .to_owned())
        })
        .await
        .map_err(|e| e.to_string())??
    } else {
        download_name(name, &kind)
    };
    let selected = rfd::AsyncFileDialog::new()
        .set_title("Save CKD file")
        .set_file_name(name)
        .save_file()
        .await;
    let Some(selected) = selected else {
        return Ok(());
    };
    tauri::async_runtime::spawn_blocking(move || {
        let mut response = app.state::<Engine>().get(&path)?;
        let destination = selected.path();
        let mut output =
            tempfile::NamedTempFile::new_in(destination.parent().ok_or("Choose an output folder")?)
                .map_err(|e| e.to_string())?;
        std::io::copy(&mut response, &mut output).map_err(|e| e.to_string())?;
        output.as_file().sync_all().map_err(|e| e.to_string())?;
        output.persist(destination).map_err(|e| e.to_string())?;
        Ok(())
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn quit(app: tauri::AppHandle) {
    let handle = app.clone();
    let _ = tauri::async_runtime::spawn_blocking(move || handle.state::<Engine>().stop()).await;
    app.exit(0);
}

fn main() {
    let app = tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            pick_path,
            reveal_path,
            save_download,
            quit
        ])
        .setup(|app| {
            let state = app.path().app_log_dir()?;
            std::fs::create_dir_all(&state)?;
            let executable = if cfg!(debug_assertions) {
                PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../engine/ckd-engine/ckd-engine")
            } else {
                app.path()
                    .resource_dir()?
                    .join("engine/ckd-engine/ckd-engine")
            };
            let (engine, url) = Engine::start(&executable, &state.join("engine.log"))
                .map_err(std::io::Error::other)?;
            let origin = engine.origin.origin();
            app.manage(engine);
            tauri::WebviewWindowBuilder::new(app, "main", tauri::WebviewUrl::External(url))
                .title("CKD Colorimetry")
                .inner_size(1440.0, 960.0)
                .min_inner_size(950.0, 680.0)
                .disable_drag_drop_handler()
                .on_navigation(move |url| url.origin() == origin)
                .build()?;
            let handle = app.handle().clone();
            std::thread::spawn(move || loop {
                std::thread::sleep(std::time::Duration::from_secs(1));
                let engine = handle.state::<Engine>();
                if engine.stopping.load(Ordering::SeqCst) { break; }
                let stopped = engine.child.lock().ok().and_then(|mut child| child.try_wait().ok().flatten()).is_some();
                if stopped {
                    engine.stopping.store(true, Ordering::SeqCst);
                    rfd::MessageDialog::new().set_title("Analysis engine stopped")
                        .set_description("Your saved project folders are preserved. Reopen CKD Colorimetry and retry any interrupted calculation.")
                        .set_level(rfd::MessageLevel::Error).show();
                    handle.exit(1);
                    break;
                }
            });
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                if !window.state::<Engine>().stopping.load(Ordering::SeqCst) {
                    api.prevent_close();
                    let _ = window.emit("ckd-close-request", ());
                }
            }
        })
        .build(tauri::generate_context!())
        .unwrap_or_else(|error| {
            rfd::MessageDialog::new()
                .set_title("CKD Colorimetry could not start")
                .set_description(error.to_string())
                .set_level(rfd::MessageLevel::Error)
                .show();
            std::process::exit(1);
        });
    app.run(|app, event| {
        if let tauri::RunEvent::ExitRequested { api, .. } = event {
            if !app.state::<Engine>().stopping.load(Ordering::SeqCst) {
                api.prevent_exit();
                let _ = app.emit("ckd-close-request", ());
            }
        }
    });
}
