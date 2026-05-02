# Raspberry Pi Host — Development & Operations Plan

> Single source of truth for the Raspberry Pi port (`v3/raspberry-pi-port`).
> Pairs with `v3-no-python-foundation-plan.md`. When this plan changes,
> change this file; do not fork notes elsewhere.

Last updated: **2026-05-02**. Branch: `v3/raspberry-pi-port`.

---

## 0. TL;DR for the next engineer

The Pi host is a standalone Linux service that exposes the same iOS
location-simulation capabilities the macOS app has, over an HTTP/HTTPS
LAN UI. Code-level work is done; what remains is **hardware validation,
portable-use ergonomics, and developer-experience polish**.

**Day-1 verification:**

```bash
# 1. Correct branch
git rev-parse --abbrev-ref HEAD            # expect: v3/raspberry-pi-port

# 2. Both crates compile (host machine, native target)
cd native-device-core && cargo build --release && cd ..
cd raspberry-pi-host && cargo fmt --check && cargo build --release && cd ..

# 3. (Optional) Cross-compile to aarch64 for the Pi
#    See §6 "Build & Cross-Compile".
```

Run the host locally without a Pi (smoke-test the HTTP surface):

```bash
GEOTELEPORT_BIND=127.0.0.1 \
GEOTELEPORT_PORT=8080 \
GEOTELEPORT_DEVICE_CORE=$PWD/native-device-core/target/release/geoteleport-device-core \
  cargo run --manifest-path raspberry-pi-host/Cargo.toml --release
# → http://127.0.0.1:8080
```

(`/api/devices` will fail without a real iPhone attached — that is
expected; the static UI and `/api/health` should still work.)

---

## 1. Scope

The Pi branch keeps the Pi host **separate from** the macOS app and any
prior Windows WebView frontend. The Pi package is a Linux service that:

- Serves its own browser UI from embedded static assets (no external
  webserver, no Node toolchain at runtime).
- Calls the shared `native-device-core` Rust APIs for iOS ≤ 16 location
  simulation.
- Manages the long-lived `ios17-location-daemon` child process for iOS
  17, iPadOS 18, and iOS 26.
- Listens on HTTP by default; opt-in HTTPS via env vars.
- Runs as a hardened systemd service under a dedicated system user.

iOS 17+ still requires Developer Mode and a mounted DeveloperDiskImage
on the device. If DVT/RSD is not advertised, the host surfaces the
daemon's startup error verbatim and the user must resolve Developer Mode
or DDI mounting before retrying. Automating DDI mounting is one of the
remaining TODOs (see §10).

**Out of scope on this branch:**
- Cloud sync / accounts / remote control beyond LAN.
- Any Android workflows.
- Mac App Store / signed-app concerns (the macOS app handles those
  separately).

---

## 2. Components

| Path | Role |
|---|---|
| `native-device-core/` | Rust library + CLI: USB enum, lockdown info, iOS ≤ 16 simulate-location, `ios17-location-daemon` |
| `raspberry-pi-host/` | Axum HTTP/HTTPS server, embedded UI, daemon-process manager |
| `raspberry-pi-host/wwwroot/` | Standalone browser UI using `/api/*` (does **not** use any Windows WebView bridge APIs) |
| `scripts/install_pi.sh` | Debian / Raspberry Pi OS installer for both binaries + systemd unit |
| `.github/workflows/raspberry-pi-port.yml` | Cross-compile workflow → `aarch64-unknown-linux-gnu` deployment artifact |
| `docs/raspberry-pi-development.md` | This file |
| `docs/v3-no-python-foundation-plan.md` | Master plan (macOS shell + cross-platform core) |

---

## 3. Architecture

```
                         Browser (Mac / phone, same LAN)
                                     │
                                     │ HTTP(S) :8080  (token-gated)
                                     ▼
┌──────────────────────────────────────────────────────────────────┐
│  raspberry-pi-host  (Axum, single binary)                        │
│  - Static UI served from rust-embed                              │
│  - /api/health, /api/devices, /api/device/:udid,                 │
│    /api/diagnostics, /api/pair, /api/location, /api/location/:udid│
│  - Token auth: x-geoteleport-token  OR  Authorization: Bearer …  │
│  - Optional TLS via axum-server + rustls                         │
├──────────────────────────────────────────────────────────────────┤
│  Per-request paths:                                              │
│   • iOS ≤ 16  → in-process call into  geoteleport_device_core    │
│                 (rlib, linked statically)                        │
│   • iOS 17+   → Ios17DaemonManager spawns / reuses one           │
│                 `geoteleport-device-core ios17-location-daemon`   │
│                 child process per UDID, talks over stdin/stdout  │
├──────────────────────────────────────────────────────────────────┤
│  USB layer (host OS plumbing)                                    │
│  - usbmuxd.service (apt package, required)                       │
│  - libimobiledevice-utils for `idevicepair` (used by /api/pair   │
│    and /api/diagnostics)                                         │
└──────────────────────────────────────────────────────────────────┘
                                     │
                                     │ USB cable
                                     ▼
                                 iPhone / iPad
```

Invariants:

- **Pi host never shells out to the user's installed tools.** The only
  external commands invoked are `usbmuxd`-related ones owned by the
  `apt`-installed package (`idevicepair`, `systemctl`).
- **Single Rust core.** Both macOS and Pi link against
  `geoteleport-device-core`. Adding a capability adds it once.
- **Pi UI is independent.** `wwwroot/` does not import any macOS or
  Windows-specific JS. It speaks plain `fetch` against `/api/*`.

---

## 4. File / runtime layout on the Pi

```
/opt/geoteleport/
├── geoteleport-host           # raspberry-pi-host binary
└── geoteleport-device-core    # device core + iOS17 daemon
/etc/geoteleport.env           # env file, root:geoteleport 0640
/etc/systemd/system/geoteleport.service
```

System user: `geoteleport` (system, no shell, home `/opt/geoteleport`),
added to `plugdev` when that group exists so it can reach usbmuxd
sockets.

systemd unit (relevant fields, see `scripts/install_pi.sh`):

```
After=network-online.target usbmuxd.service
Requires=usbmuxd.service
EnvironmentFile=/etc/geoteleport.env
ExecStart=/opt/geoteleport/geoteleport-host
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
```

`PrivateDevices` is **not** set (defaults to `false`) so the service can
reach USB devices through usbmuxd.

---

## 5. Configuration reference

Everything is environment-variable driven. The installer writes defaults
to `/etc/geoteleport.env`; edit and `systemctl restart geoteleport` to
apply.

| Variable | Default | Purpose |
|---|---|---|
| `GEOTELEPORT_BIND` | `0.0.0.0` | Listen address |
| `GEOTELEPORT_PORT` | `8080` | Listen port |
| `GEOTELEPORT_TOKEN` | (random 16 bytes at install) | Required header value; empty disables auth |
| `GEOTELEPORT_DEVICE_CORE` | `geoteleport-device-core` (PATH) | Path to the device-core binary used for the iOS 17 daemon |
| `GEOTELEPORT_TLS_CERT` | unset | If set together with `GEOTELEPORT_TLS_KEY`, server binds HTTPS |
| `GEOTELEPORT_TLS_KEY` | unset | Private key path (PEM) |

Auth header forms (either accepted):

```
x-geoteleport-token: <token>
Authorization: Bearer <token>
```

---

## 6. Build & Cross-Compile

### 6.1 CI artifact (recommended path)

`.github/workflows/raspberry-pi-port.yml` builds for
`aarch64-unknown-linux-gnu` on every push/PR that touches
`native-device-core/`, `raspberry-pi-host/`, the install script, or the
workflow itself. Output artifact `geoteleport-pi-aarch64` contains:

- `raspberry-pi-host/target/aarch64-unknown-linux-gnu/release/raspberry-pi-host`
- `native-device-core/target/aarch64-unknown-linux-gnu/release/geoteleport-device-core`
- `scripts/install_pi.sh`

Download from the Actions tab → `scp` to Pi → run `install_pi.sh`.

### 6.2 Local cross-compile on macOS (optional)

This is **not yet codified in the repo** (see §10 TODO). Working recipe:

```bash
brew install aarch64-elf-gcc                   # cross linker
rustup target add aarch64-unknown-linux-gnu

# Per-crate one-shot (no checked-in config):
CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-elf-gcc \
  cargo build --release --target aarch64-unknown-linux-gnu \
  --manifest-path raspberry-pi-host/Cargo.toml

CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-elf-gcc \
  cargo build --release --target aarch64-unknown-linux-gnu \
  --bin geoteleport-device-core \
  --manifest-path native-device-core/Cargo.toml
```

A future commit should drop a `.cargo/config.toml` so this becomes a
plain `cargo build --target aarch64-unknown-linux-gnu`.

### 6.3 Native build for testing

On the Pi or a same-arch dev box, `cargo build --release` in either
crate is enough.

---

## 7. Deployment (end-to-end)

### 7.1 Flash the SD card (one time, on macOS)

```bash
brew install --cask raspberry-pi-imager
open -a "Raspberry Pi Imager"
```

In Imager → Choose Device → Choose OS = **Raspberry Pi OS Lite (64-bit)**
→ Choose Storage = the SD card → Next → **EDIT SETTINGS** (mandatory
for headless setup):

- General: hostname `geoteleport-pi`, username + password, Wi-Fi SSID
  + password, country `CN`, time zone `Asia/Shanghai`.
- Services: ☑ Enable SSH (password auth, or paste your `~/.ssh/id_*.pub`).
- Pi Connect / RPi Connect: leave unchecked (LAN-only is enough).

Save → YES → write + verify (~5–10 min) → eject → insert into Pi → power on.

### 7.2 SSH in

```bash
ssh <user>@geoteleport-pi.local
# or look up the IP via the router / arp -a
```

### 7.3 Install the service

Copy the build artifact to the Pi:

```bash
scp raspberry-pi-host geoteleport-device-core install_pi.sh \
    <user>@geoteleport-pi.local:~/
```

On the Pi:

```bash
chmod +x install_pi.sh raspberry-pi-host geoteleport-device-core
sudo ./install_pi.sh ./raspberry-pi-host ./geoteleport-device-core
```

The installer:
1. `apt install usbmuxd libimobiledevice-utils curl`.
2. Creates the `geoteleport` system user (joins `plugdev` if present).
3. Installs both binaries to `/opt/geoteleport/`.
4. Generates a random 16-byte hex token (or honors a pre-set
   `GEOTELEPORT_TOKEN` env var).
5. Writes `/etc/geoteleport.env` and the systemd unit.
6. `systemctl enable --now geoteleport.service`.
7. Prints the LAN URL and token.

### 7.4 First UI use

Open `http://<pi-ip>:8080` from any device on the same network, paste
the token, plug in the iPhone, click **Pair / Trust**, accept the trust
prompt on the phone, then enter coordinates and **Set**.

---

## 8. Day-2 operations

### 8.1 Logs

```bash
sudo journalctl -u geoteleport -f                # follow
sudo journalctl -u geoteleport --since "10 min ago"
sudo systemctl status geoteleport
```

### 8.2 Token rotation

```bash
sudo sed -i "s/^GEOTELEPORT_TOKEN=.*/GEOTELEPORT_TOKEN=$(openssl rand -hex 16)/" /etc/geoteleport.env
sudo systemctl restart geoteleport
sudo grep ^GEOTELEPORT_TOKEN /etc/geoteleport.env
```

### 8.3 HTTPS

```bash
sudo mkdir -p /etc/geoteleport
# Self-signed for LAN use:
sudo openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
  -keyout /etc/geoteleport/key.pem \
  -out    /etc/geoteleport/cert.pem \
  -subj "/CN=geoteleport-pi.local" \
  -addext "subjectAltName=DNS:geoteleport-pi.local,DNS:localhost,IP:<pi-ip>"
sudo chown root:geoteleport /etc/geoteleport/key.pem /etc/geoteleport/cert.pem
sudo chmod 0640 /etc/geoteleport/key.pem
echo "GEOTELEPORT_TLS_CERT=/etc/geoteleport/cert.pem" | sudo tee -a /etc/geoteleport.env
echo "GEOTELEPORT_TLS_KEY=/etc/geoteleport/key.pem"   | sudo tee -a /etc/geoteleport.env
sudo systemctl restart geoteleport
```

Browsers will warn about the self-signed cert; accept once per device.

### 8.4 Portable / out-of-home use

For taking the Pi outside, configure a Wi-Fi access point so a phone or
laptop can connect to the Pi directly **without any external network**.
Raspberry Pi OS Bookworm uses NetworkManager:

```bash
sudo nmcli device wifi hotspot ifname wlan0 ssid GeoPi password 'YourStrongPwd'
sudo nmcli connection modify Hotspot \
  connection.autoconnect yes \
  connection.autoconnect-priority 100
```

Default network is `10.42.0.0/24`; the Pi is `10.42.0.1`. Reach the UI
at `http://10.42.0.1:8080`. Switching back to home Wi-Fi:

```bash
sudo nmcli connection down Hotspot
sudo nmcli connection up <home-ssid>
```

A future commit should ship this as a helper command in
`scripts/install_pi.sh` (see §10 TODO).

### 8.5 Updates

Until an updater ships, the manual flow is:

```bash
# On Mac, after pulling new artifact:
scp raspberry-pi-host geoteleport-device-core <user>@geoteleport-pi.local:~/

# On Pi:
sudo install -m 0755 ~/raspberry-pi-host        /opt/geoteleport/geoteleport-host
sudo install -m 0755 ~/geoteleport-device-core  /opt/geoteleport/geoteleport-device-core
sudo systemctl restart geoteleport
```

---

## 9. API reference

All endpoints live under `/api`. Token (when set) goes in
`x-geoteleport-token` or `Authorization: Bearer …`. JSON unless noted.

| Method | Path | Body | Response |
|---|---|---|---|
| GET | `/api/health` | — | `{ status, authRequired, deviceCore }` |
| GET | `/api/devices` | — | Array from `enumerate_ios_devices_core` |
| GET | `/api/device/:udid` | — | Device-info JSON |
| GET | `/api/diagnostics` | — | `{ devices, commands: { usbmuxd, pairing }, notes }` |
| POST | `/api/pair` | — | Result of `idevicepair pair` |
| POST | `/api/location` | `{ udid, lat, lon }` | `{ status: "ok" }` or error |
| DELETE | `/api/location/:udid` | — | `{ status: "ok" }` or error |

Validation: lat in `[-90, 90]`, lon in `[-180, 180]`, both finite.
Routing: iOS major ≥ 17 → `Ios17DaemonManager`; otherwise → in-process
core call.

---

## 10. Outstanding work / TODO

Ordered by impact. Tick items off here, not in scattered TODO comments.

### Hardware & protocol coverage
- [ ] **Hardware smoke test on Raspberry Pi OS 64-bit** with iOS 16,
      iPadOS 18, and iOS 26. Capture pass/fail per device class in the
      change log.
- [ ] **Automated DeveloperDiskImage mount for iOS 17+** when the DVT
      service is not advertised. Today the daemon errors out and the
      user must mount via macOS first.
- [ ] **Device pairing UX in the UI**: surface "tap Trust on the phone"
      progression instead of relying on `idevicepair`'s opaque output.

### Ergonomics & dev-loop
- [ ] **Local cross-compile**: check in `.cargo/config.toml` and a
      `Makefile` / `justfile` target so `cargo build --target
      aarch64-unknown-linux-gnu` and a one-shot `make deploy
      PI=geoteleport-pi.local` work without env-var voodoo.
- [ ] **Auto-update mechanism**: minimal HTTP-pull updater or
      `apt`-style channel; until then, §8.5 manual flow.
- [ ] **Hotspot helper**: extend `install_pi.sh` (or a sibling
      `scripts/configure_pi_hotspot.sh`) to wrap the `nmcli` recipe in
      §8.4 with sensible defaults and toggling.
- [ ] **TLS bootstrap**: bake the §8.3 self-signed-cert recipe into a
      script so HTTPS is one command.
- [ ] **Token rotation helper**: `scripts/rotate_token.sh`.

### Code quality
- [ ] **Integration tests for `raspberry-pi-host`**: at minimum the
      auth header logic, coordinate validation, daemon manager
      restart-on-failure, and TLS bootstrap. Currently zero tests in
      the crate.
- [ ] **Frontend hardening**: input persistence (token, last UDID,
      last coordinates) in `localStorage`; clearer error rendering
      from `/api/diagnostics`; minimal i18n scaffolding.
- [ ] **Origin / CORS policy review**: today any Origin can hit `/api`
      with the right token. Decide whether to add same-origin or a
      configurable allowlist.

### Documentation
- [ ] **README pointer**: link this doc from the top-level `README.md`
      so a Pi-curious reader does not have to find `docs/` first.
- [ ] **Diagrams**: add a topology diagram for the portable-use
      scenario (Pi hotspot + phone + Mac).

---

## 11. Code map for picking up

Read these in order:

- `raspberry-pi-host/src/main.rs` — Axum router, auth, state, daemon
  manager, static-asset serving. ~600 lines.
- `raspberry-pi-host/wwwroot/index.html` + `app.js` + `style.css` —
  static UI. Plain HTML/JS/CSS, no bundler.
- `native-device-core/src/main.rs` — CLI entry points incl.
  `ios17-location-daemon`.
- `native-device-core/src/core.rs` — shared Rust device-core logic
  (used by both the Mac app via FFI and the Pi host as an rlib
  dependency).
- `scripts/install_pi.sh` — installer; reflects the supported runtime
  shape.
- `.github/workflows/raspberry-pi-port.yml` — build matrix and
  artifact contract.

After any Rust change:

```bash
cargo fmt --check --manifest-path raspberry-pi-host/Cargo.toml
cargo build --release --manifest-path native-device-core/Cargo.toml
cargo build --release --manifest-path raspberry-pi-host/Cargo.toml
```

---

## 12. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `/api/devices` returns empty | usbmuxd not running, or iPhone locked / not trusted. Check `systemctl status usbmuxd`; tap Trust on the phone; call `POST /api/pair`. |
| `ios17-location-daemon: DTX service com.apple.instruments.dtservicehub is not advertised` | Developer Mode disabled on iPhone OR DDI not mounted. Enable Developer Mode, mount DDI (Xcode/macOS app for now), retry. |
| `ios17-location-daemon: did not become ready within 45 seconds` | Often follows a flaky CoreDeviceProxy connect. The daemon already retries internally 3×; if it persists, replug the cable, then `systemctl restart geoteleport`. |
| `401 missing or invalid API token` | Token mismatch. Re-read `/etc/geoteleport.env`, paste exactly. |
| HTTPS browser warning | Self-signed cert is expected; accept once. For zero-warning setup, use a real cert from your LAN CA. |
| Service runs but `:8080` refused from other hosts | `GEOTELEPORT_BIND` is `127.0.0.1` instead of `0.0.0.0`, or the Pi has a firewall/ufw rule. |
| Multiple iPhones plugged in | The API operates per-UDID; pass the right `udid` in `/api/location` and `/api/device/:udid`. UI selection lives in `wwwroot/app.js`. |

---

## 13. Change log for this plan

- **2026-05-02 — Initial development doc.** Replaces the earlier
  `raspberry-pi-deployment-plan.md` skeleton with a comprehensive plan
  covering architecture, deployment, configuration, ops, API,
  outstanding work, and troubleshooting. The previous deployment plan
  is now a stub redirecting here.
