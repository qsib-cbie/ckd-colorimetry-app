use serde::Deserialize;
use std::{
    io::{BufRead, BufReader},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Mutex,
    },
    time::Duration,
};

#[derive(Deserialize)]
struct Started {
    url: String,
}

pub struct Engine {
    pub child: Mutex<Child>,
    pub origin: reqwest::Url,
    pub token: String,
    pub stopping: AtomicBool,
}

impl Engine {
    pub fn start(executable: &Path, log: &Path) -> Result<(Self, reqwest::Url), String> {
        let output = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(log)
            .map_err(|e| e.to_string())?;
        let mut child = Command::new(executable)
            .arg("--parent-pipe")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(output)
            .env("OMP_NUM_THREADS", "2")
            .spawn()
            .map_err(|e| format!("Cannot start the bundled analysis engine: {e}"))?;
        let stdout = child.stdout.take().ok_or("Engine output is unavailable")?;
        let (send, receive) = mpsc::channel();
        std::thread::spawn(move || {
            let line = BufReader::new(stdout).lines().next().transpose();
            let _ = send.send(line);
        });
        let started = receive
            .recv_timeout(Duration::from_secs(30))
            .map_err(|_| "The analysis engine did not start. Check engine.log.")?
            .map_err(|e| e.to_string())?
            .ok_or("The analysis engine stopped during startup. Check engine.log.")?;
        let info: Started = serde_json::from_str(&started).map_err(|e| e.to_string())?;
        let launch = reqwest::Url::parse(&info.url).map_err(|e| e.to_string())?;
        let (origin, token) = launch_parts(&launch)?;
        let engine = Self {
            child: Mutex::new(child),
            origin,
            token,
            stopping: AtomicBool::new(false),
        };
        for _ in 0..100 {
            if engine.get("/api/ready").is_ok() {
                return Ok((engine, launch));
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        engine.stop();
        Err("The analysis engine did not become ready. Check engine.log.".into())
    }

    pub fn get(&self, path: &str) -> Result<reqwest::blocking::Response, String> {
        let url = self.origin.join(path).map_err(|e| e.to_string())?;
        reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(120))
            .no_proxy()
            .build()
            .map_err(|e| e.to_string())?
            .get(url)
            .header("X-CKD-Token", &self.token)
            .send()
            .and_then(|response| response.error_for_status())
            .map_err(|e| e.to_string())
    }

    pub fn workspace_path(&self, path: &Path) -> Result<PathBuf, String> {
        let info: serde_json::Value = self
            .get("/api/workspace")?
            .json()
            .map_err(|e| e.to_string())?;
        let root = info["root"].as_str().ok_or("Open a workspace first")?;
        contained_path(Path::new(root), path)
    }

    pub fn stop(&self) {
        if self.stopping.swap(true, Ordering::SeqCst) {
            return;
        }
        if let Ok(mut child) = self.child.lock() {
            drop(child.stdin.take());
            let _ = child.wait();
        }
    }
}

pub fn launch_parts(launch: &reqwest::Url) -> Result<(reqwest::Url, String), String> {
    if launch.scheme() != "http"
        || launch.host_str() != Some("127.0.0.1")
        || launch.port().is_none()
    {
        return Err("Engine must use a private local address".into());
    }
    let token = launch
        .path()
        .strip_prefix("/launch/")
        .filter(|value| value.len() >= 32 && !value.contains('/'))
        .ok_or("Invalid engine launch response")?
        .to_owned();
    let mut origin = launch.clone();
    origin.set_path("/");
    origin.set_query(None);
    origin.set_fragment(None);
    Ok((origin, token))
}

pub fn contained_path(root: &Path, path: &Path) -> Result<PathBuf, String> {
    let root = root.canonicalize().map_err(|e| e.to_string())?;
    let path = path.canonicalize().map_err(|e| e.to_string())?;
    if !path.starts_with(root) {
        return Err("Choose a file in the open workspace".into());
    }
    Ok(path)
}

pub fn download_kind(path: &str) -> Result<&str, String> {
    let (route, query) = path.split_once('?').unwrap_or((path, ""));
    let pieces: Vec<_> = route.split('/').collect();
    if pieces.len() != 5
        || !pieces[0].is_empty()
        || pieces[1] != "api"
        || pieces[2] != "analyses"
        || pieces[3].len() != 32
        || !pieces[3].bytes().all(|c| c.is_ascii_hexdigit())
        || !["export", "original", "coordinates"].contains(&pieces[4])
        || !(query.is_empty()
            || pieces[4] == "export" && ["debug_rasters=1", "debug_rasters=0"].contains(&query))
    {
        return Err("Choose an analysis download".into());
    }
    Ok(pieces[4])
}

pub fn download_name(requested: Option<String>, kind: &str) -> String {
    let (extension, fallback) = if kind == "export" {
        (".zip", "ckd-analysis.zip")
    } else {
        (".json", "coordinates.json")
    };
    requested
        .filter(|name| {
            name.len() <= 200
                && !name.starts_with('.')
                && !name.contains(['/', '\\', ':'])
                && name.to_lowercase().ends_with(extension)
                && name.len() > extension.len()
        })
        .unwrap_or_else(|| fallback.into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn engine_address_is_loopback_and_contains_a_secret() {
        let secret = "a".repeat(43);
        let url = reqwest::Url::parse(&format!("http://127.0.0.1:1234/launch/{secret}")).unwrap();
        let (origin, token) = launch_parts(&url).unwrap();
        assert_eq!(origin.as_str(), "http://127.0.0.1:1234/");
        assert_eq!(token, secret);
        for invalid in [
            "https://example.com:1234/launch/x",
            "http://localhost:1234/launch/x",
            "http://127.0.0.1:1234/launch/short",
        ] {
            assert!(launch_parts(&reqwest::Url::parse(invalid).unwrap()).is_err());
        }
    }
    #[test]
    fn download_paths_cannot_escape_or_select_other_routes() {
        assert_eq!(
            download_kind(&format!("/api/analyses/{}/export", "a".repeat(32))).unwrap(),
            "export"
        );
        assert_eq!(
            download_kind(&format!(
                "/api/analyses/{}/export?debug_rasters=0",
                "a".repeat(32)
            ))
            .unwrap(),
            "export"
        );
        for path in [
            "https://other/export",
            "/api/workspace",
            "/api/analyses/../../export",
            "/api/analyses/123/export?path=/etc/passwd",
            &format!("/api/analyses/{}/export?path=/etc/passwd", "a".repeat(32)),
            &format!("/api/analyses/{}/original?debug_rasters=1", "a".repeat(32)),
        ] {
            assert!(download_kind(path).is_err());
        }
    }
    #[test]
    fn suggested_download_names_are_plain_file_names() {
        assert_eq!(
            download_name(Some("Sample A_2026-09-30_101500.zip".into()), "export"),
            "Sample A_2026-09-30_101500.zip"
        );
        for name in [
            "../escape.zip",
            "/tmp/a.zip",
            ".hidden.zip",
            "notes.txt",
            ".zip",
            "a:b.zip",
        ] {
            assert_eq!(
                download_name(Some(name.into()), "export"),
                "ckd-analysis.zip"
            );
        }
        assert_eq!(download_name(None, "coordinates"), "coordinates.json");
    }
    #[test]
    fn finder_paths_follow_workspace_boundary() {
        let root = tempfile::tempdir().unwrap();
        let file = root.path().join("sample");
        std::fs::write(&file, "test").unwrap();
        assert_eq!(
            contained_path(root.path(), &file).unwrap(),
            file.canonicalize().unwrap()
        );
        assert!(contained_path(root.path(), Path::new("/etc/passwd")).is_err());
    }
}
