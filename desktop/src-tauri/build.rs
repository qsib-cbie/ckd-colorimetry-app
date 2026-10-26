fn main() {
    let manifest = tauri_build::AppManifest::new().commands(&[
        "pick_path",
        "reveal_path",
        "save_download",
        "quit",
    ]);
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(manifest))
        .expect("Desktop permissions could not be generated");
}
