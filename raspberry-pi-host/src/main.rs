use axum::{
    body::Body,
    extract::{Path, State},
    http::{header, HeaderMap, StatusCode, Uri},
    response::{IntoResponse, Response},
    routing::{delete, get, post},
    Json, Router,
};
use geoteleport_device_core::core::{
    clear_location_core, device_info_core, enumerate_ios_devices_core, find_usb_device,
    get_ios_major, set_location_core,
};
use rust_embed::RustEmbed;
use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::HashMap, env, net::SocketAddr, process::Stdio, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::{Child, ChildStderr, ChildStdin, ChildStdout, Command},
    sync::Mutex,
    time,
};

#[derive(Clone)]
struct AppState {
    token: Option<Arc<str>>,
    ios17_daemons: Arc<Ios17DaemonManager>,
}

#[derive(Deserialize)]
struct LocationRequest {
    udid: String,
    lat: f64,
    lon: f64,
}

#[derive(RustEmbed)]
#[folder = "wwwroot"]
struct WebAssets;

#[tokio::main]
async fn main() {
    let bind = env::var("GEOTELEPORT_BIND").unwrap_or_else(|_| "0.0.0.0".to_string());
    let port = env::var("GEOTELEPORT_PORT")
        .ok()
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(8080);
    let addr: SocketAddr = format!("{bind}:{port}")
        .parse()
        .expect("GEOTELEPORT_BIND and GEOTELEPORT_PORT must form a valid socket address");

    let token = env::var("GEOTELEPORT_TOKEN")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .map(Arc::<str>::from);
    let state = AppState {
        token,
        ios17_daemons: Arc::new(Ios17DaemonManager::from_env()),
    };

    let app = Router::new()
        .route("/api/health", get(health))
        .route("/api/devices", get(list_devices))
        .route("/api/device/:udid", get(device_info))
        .route("/api/diagnostics", get(diagnostics))
        .route("/api/pair", post(pair_device))
        .route("/api/location", post(set_location))
        .route("/api/location/:udid", delete(clear_location))
        .fallback(static_asset)
        .with_state(state);

    let tls_cert = env::var("GEOTELEPORT_TLS_CERT").ok();
    let tls_key = env::var("GEOTELEPORT_TLS_KEY").ok();

    if let (Some(cert_path), Some(key_path)) = (tls_cert, tls_key) {
        let config = axum_server::tls_rustls::RustlsConfig::from_pem_file(cert_path, key_path)
            .await
            .expect("failed to load TLS config");
        println!("GeoTeleport Pi host listening on https://{addr}");
        axum_server::bind_rustls(addr, config)
            .serve(app.into_make_service())
            .await
            .expect("GeoTeleport Pi host HTTPS server failed");
    } else {
        let listener = tokio::net::TcpListener::bind(addr)
            .await
            .expect("failed to bind GeoTeleport Pi host");
        println!("GeoTeleport Pi host listening on http://{addr}");
        axum::serve(listener, app)
            .await
            .expect("GeoTeleport Pi host HTTP server failed");
    }
}

async fn health(State(state): State<AppState>) -> Json<Value> {
    Json(json!({
        "status": "ok",
        "authRequired": state.token.is_some(),
        "deviceCore": state.ios17_daemons.binary_path()
    }))
}

async fn list_devices(State(state): State<AppState>, headers: HeaderMap) -> Response {
    if let Err(response) = authorize(&state, &headers) {
        return response;
    }

    core_json_response(enumerate_ios_devices_core().await)
}

async fn device_info(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(udid): Path<String>,
) -> Response {
    if let Err(response) = authorize(&state, &headers) {
        return response;
    }

    if udid.trim().is_empty() {
        return error_response(StatusCode::BAD_REQUEST, "missing device UDID");
    }

    core_json_response(device_info_core(&udid).await)
}

async fn set_location(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<LocationRequest>,
) -> Response {
    if let Err(response) = authorize(&state, &headers) {
        return response;
    }

    if request.udid.trim().is_empty() {
        return error_response(StatusCode::BAD_REQUEST, "missing device UDID");
    }
    if let Err(message) = validate_coordinates(request.lat, request.lon) {
        return error_response(StatusCode::BAD_REQUEST, message);
    }

    match device_ios_major(&request.udid).await {
        Ok(Some(major)) if major >= 17 => core_json_response(
            state
                .ios17_daemons
                .set_location(&request.udid, request.lat, request.lon)
                .await,
        ),
        Ok(_) => {
            core_json_response(set_location_core(&request.udid, request.lat, request.lon).await)
        }
        Err(error) => error_response(StatusCode::BAD_GATEWAY, error),
    }
}

async fn clear_location(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(udid): Path<String>,
) -> Response {
    if let Err(response) = authorize(&state, &headers) {
        return response;
    }

    if udid.trim().is_empty() {
        return error_response(StatusCode::BAD_REQUEST, "missing device UDID");
    }

    match device_ios_major(&udid).await {
        Ok(Some(major)) if major >= 17 => {
            core_json_response(state.ios17_daemons.clear_location(&udid).await)
        }
        Ok(_) => core_json_response(clear_location_core(&udid).await),
        Err(error) => error_response(StatusCode::BAD_GATEWAY, error),
    }
}

async fn diagnostics(State(state): State<AppState>, headers: HeaderMap) -> Response {
    if let Err(response) = authorize(&state, &headers) {
        return response;
    }

    let devices = enumerate_ios_devices_core()
        .await
        .ok()
        .and_then(|body| serde_json::from_str::<Value>(&body).ok())
        .unwrap_or_else(|| json!([]));

    let usbmuxd = run_command(
        "systemctl",
        &["is-active", "usbmuxd"],
        Duration::from_secs(5),
    )
    .await;
    let pair = run_command("idevicepair", &["validate"], Duration::from_secs(10)).await;

    (
        StatusCode::OK,
        Json(json!({
            "status": "ok",
            "devices": devices,
            "commands": {
                "usbmuxd": usbmuxd,
                "pairing": pair
            },
            "notes": [
                "Use Pair / Trust when the iPhone first connects, then accept the trust prompt on the device.",
                "iOS 17, iPadOS 18, and iOS 26 need Developer Mode and the RSD DVT location service to be available."
            ]
        })),
    )
        .into_response()
}

async fn pair_device(State(state): State<AppState>, headers: HeaderMap) -> Response {
    if let Err(response) = authorize(&state, &headers) {
        return response;
    }

    let result = run_command("idevicepair", &["pair"], Duration::from_secs(30)).await;
    (
        StatusCode::OK,
        Json(json!({ "status": "ok", "command": result })),
    )
        .into_response()
}

fn authorize(_state: &AppState, _headers: &HeaderMap) -> Result<(), Response> {
    Ok(())
}

fn validate_coordinates(lat: f64, lon: f64) -> Result<(), &'static str> {
    if !lat.is_finite() || !lon.is_finite() {
        return Err("coordinates must be finite numbers");
    }
    if !(-90.0..=90.0).contains(&lat) {
        return Err("latitude must be between -90 and 90");
    }
    if !(-180.0..=180.0).contains(&lon) {
        return Err("longitude must be between -180 and 180");
    }
    Ok(())
}

async fn device_ios_major(udid: &str) -> Result<Option<u32>, String> {
    let device = find_usb_device(udid).await?;
    Ok(get_ios_major(device.device_id).await)
}

fn core_json_response(result: Result<String, String>) -> Response {
    match result {
        Ok(body) => match serde_json::from_str::<Value>(&body) {
            Ok(value) => (StatusCode::OK, Json(value)).into_response(),
            Err(error) => error_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("core returned invalid JSON: {error}"),
            ),
        },
        Err(error) => error_response(StatusCode::BAD_GATEWAY, error),
    }
}

async fn run_command(program: &str, args: &[&str], timeout: Duration) -> Value {
    let output = time::timeout(timeout, Command::new(program).args(args).output()).await;
    match output {
        Ok(Ok(output)) => json!({
            "program": program,
            "args": args,
            "ok": output.status.success(),
            "exitCode": output.status.code(),
            "stdout": String::from_utf8_lossy(&output.stdout).trim(),
            "stderr": String::from_utf8_lossy(&output.stderr).trim()
        }),
        Ok(Err(error)) => json!({
            "program": program,
            "args": args,
            "ok": false,
            "error": error.to_string()
        }),
        Err(_) => json!({
            "program": program,
            "args": args,
            "ok": false,
            "error": format!("timed out after {} seconds", timeout.as_secs())
        }),
    }
}

struct Ios17DaemonManager {
    binary_path: String,
    sessions: Mutex<HashMap<String, Ios17DaemonSession>>,
    startup_timeout: Duration,
    command_timeout: Duration,
}

impl Ios17DaemonManager {
    fn from_env() -> Self {
        Self {
            binary_path: env::var("GEOTELEPORT_DEVICE_CORE")
                .unwrap_or_else(|_| "geoteleport-device-core".to_string()),
            sessions: Mutex::new(HashMap::new()),
            startup_timeout: Duration::from_secs(45),
            command_timeout: Duration::from_secs(10),
        }
    }

    fn binary_path(&self) -> &str {
        &self.binary_path
    }

    async fn set_location(&self, udid: &str, lat: f64, lon: f64) -> Result<String, String> {
        self.command(udid, format!("set {lat} {lon}")).await
    }

    async fn clear_location(&self, udid: &str) -> Result<String, String> {
        self.command(udid, "clear".to_string()).await
    }

    async fn command(&self, udid: &str, command: String) -> Result<String, String> {
        let mut sessions = self.sessions.lock().await;
        let session = self.ensure_session(&mut sessions, udid).await?;
        let result = session.command(&command, self.command_timeout).await;

        if result.is_err() {
            if let Some(mut failed) = sessions.remove(udid) {
                failed.shutdown().await;
            }
        }

        result
    }

    async fn ensure_session<'a>(
        &self,
        sessions: &'a mut HashMap<String, Ios17DaemonSession>,
        udid: &str,
    ) -> Result<&'a mut Ios17DaemonSession, String> {
        let should_restart = match sessions.get_mut(udid) {
            Some(session) => !session.is_running(),
            None => true,
        };

        if should_restart {
            if let Some(mut old_session) = sessions.remove(udid) {
                old_session.shutdown().await;
            }
            let session = self.start_session(udid).await?;
            sessions.insert(udid.to_string(), session);
        }

        sessions
            .get_mut(udid)
            .ok_or_else(|| "ios17-location-daemon: session missing after startup".to_string())
    }

    async fn start_session(&self, udid: &str) -> Result<Ios17DaemonSession, String> {
        let mut child = Command::new(&self.binary_path)
            .arg("ios17-location-daemon")
            .arg(udid)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|error| {
                format!(
                    "ios17-location-daemon: failed to launch {}: {error}",
                    self.binary_path
                )
            })?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| "ios17-location-daemon: stdin pipe unavailable".to_string())?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "ios17-location-daemon: stdout pipe unavailable".to_string())?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| "ios17-location-daemon: stderr pipe unavailable".to_string())?;

        let stderr_text = Arc::new(Mutex::new(String::new()));
        spawn_stderr_reader(stderr, Arc::clone(&stderr_text));

        let mut session = Ios17DaemonSession {
            child,
            stdin,
            stdout: BufReader::new(stdout),
            stderr_text,
        };

        match time::timeout(self.startup_timeout, session.read_line()).await {
            Ok(Ok(Some(line))) if line == "READY" => Ok(session),
            Ok(Ok(Some(line))) => {
                let stderr = session.stderr_summary().await;
                session.shutdown().await;
                Err(format!(
                    "ios17-location-daemon: unexpected startup output `{line}`{}",
                    format_stderr_suffix(&stderr)
                ))
            }
            Ok(Ok(None)) => {
                let stderr = session.stderr_summary().await;
                session.shutdown().await;
                Err(format!(
                    "ios17-location-daemon: exited before READY{}",
                    format_stderr_suffix(&stderr)
                ))
            }
            Ok(Err(error)) => {
                session.shutdown().await;
                Err(error)
            }
            Err(_) => {
                let stderr = session.stderr_summary().await;
                session.shutdown().await;
                Err(format!(
                    "ios17-location-daemon: did not become ready within {} seconds{}",
                    self.startup_timeout.as_secs(),
                    format_stderr_suffix(&stderr)
                ))
            }
        }
    }
}

struct Ios17DaemonSession {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    stderr_text: Arc<Mutex<String>>,
}

impl Ios17DaemonSession {
    fn is_running(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }

    async fn command(&mut self, command: &str, timeout: Duration) -> Result<String, String> {
        self.stdin
            .write_all(format!("{command}\n").as_bytes())
            .await
            .map_err(|error| format!("ios17-location-daemon: failed to send command: {error}"))?;
        self.stdin
            .flush()
            .await
            .map_err(|error| format!("ios17-location-daemon: failed to flush command: {error}"))?;

        let line = match time::timeout(timeout, self.read_line()).await {
            Ok(Ok(Some(line))) => line,
            Ok(Ok(None)) => {
                let stderr = self.stderr_summary().await;
                return Err(format!(
                    "ios17-location-daemon: exited before command response{}",
                    format_stderr_suffix(&stderr)
                ));
            }
            Ok(Err(error)) => return Err(error),
            Err(_) => {
                let stderr = self.stderr_summary().await;
                return Err(format!(
                    "ios17-location-daemon: no response within {} seconds{}",
                    timeout.as_secs(),
                    format_stderr_suffix(&stderr)
                ));
            }
        };

        let payload: Value = serde_json::from_str(&line)
            .map_err(|error| format!("ios17-location-daemon: invalid response JSON: {error}"))?;
        if payload.get("status").and_then(Value::as_str) == Some("ok") {
            Ok(line)
        } else {
            Err(payload
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("ios17-location-daemon command failed")
                .to_string())
        }
    }

    async fn read_line(&mut self) -> Result<Option<String>, String> {
        let mut line = String::new();
        match self.stdout.read_line(&mut line).await {
            Ok(0) => Ok(None),
            Ok(_) => Ok(Some(line.trim_end_matches(['\r', '\n']).to_string())),
            Err(error) => Err(format!(
                "ios17-location-daemon: stdout read failed: {error}"
            )),
        }
    }

    async fn stderr_summary(&self) -> String {
        let text = self.stderr_text.lock().await;
        text.trim().to_string()
    }

    async fn shutdown(&mut self) {
        let _ = self.stdin.shutdown().await;
        let _ = self.child.start_kill();
        let _ = time::timeout(Duration::from_secs(2), self.child.wait()).await;
    }
}

fn spawn_stderr_reader(stderr: ChildStderr, stderr_text: Arc<Mutex<String>>) {
    tokio::spawn(async move {
        let mut reader = BufReader::new(stderr);
        let mut line = String::new();
        loop {
            line.clear();
            match reader.read_line(&mut line).await {
                Ok(0) => break,
                Ok(_) => {
                    let mut text = stderr_text.lock().await;
                    text.push_str(&line);
                    if text.len() > 4_000 {
                        let keep_from = text.len().saturating_sub(4_000);
                        text.drain(..keep_from);
                    }
                }
                Err(_) => break,
            }
        }
    });
}

fn format_stderr_suffix(stderr: &str) -> String {
    if stderr.is_empty() {
        String::new()
    } else {
        format!("; stderr: {stderr}")
    }
}

fn error_response(status: StatusCode, message: impl Into<String>) -> Response {
    (
        status,
        Json(json!({
            "status": "error",
            "error": message.into()
        })),
    )
        .into_response()
}

async fn static_asset(uri: Uri) -> Response {
    let path = uri.path().trim_start_matches('/');
    let path = if path.is_empty() { "index.html" } else { path };

    if let Some(response) = embedded_asset_response(path) {
        return response;
    }

    if path.contains('.') {
        return StatusCode::NOT_FOUND.into_response();
    }

    embedded_asset_response("index.html").unwrap_or_else(|| StatusCode::NOT_FOUND.into_response())
}

fn embedded_asset_response(path: &str) -> Option<Response> {
    let asset = WebAssets::get(path)?;
    let mime = mime_guess::from_path(path).first_or_octet_stream();

    Some(
        Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, mime.as_ref())
            .body(Body::from(asset.data.into_owned()))
            .expect("embedded asset response must be valid"),
    )
}
