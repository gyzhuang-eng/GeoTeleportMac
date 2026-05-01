# Raspberry Pi Deployment Plan

## Scope

The Raspberry Pi branch keeps the Pi host separate from the macOS app and the old Windows WebView frontend. The Pi package is a Linux service that serves its own browser UI, calls the shared `native-device-core` Rust APIs for iOS 16 and earlier, and manages the `ios17-location-daemon` child process for iOS 17, iPadOS 18, and iOS 26.

iOS 17 and later still require Developer Mode and the DVT/RSD location service to be available on the device. If that service is not advertised, the host reports the daemon startup error and the user must resolve Developer Mode or DeveloperDiskImage mounting before retrying.

## Components

- `native-device-core`: shared device enumeration, lockdown info, iOS 16 location simulation, and the `ios17-location-daemon` binary.
- `raspberry-pi-host`: Axum HTTP server with embedded static assets.
- `raspberry-pi-host/wwwroot`: standalone browser UI using `/api/*`, not Windows WebView bridge APIs.
- `scripts/install_pi.sh`: Debian/Raspberry Pi OS installer for both compiled binaries and the systemd service.
- `.github/workflows/raspberry-pi-port.yml`: ARM64 Linux build workflow.

## Runtime

Install Raspberry Pi OS 64-bit, enable SSH if needed, then build or download the `aarch64-unknown-linux-gnu` deployment bundle. On the Pi:

```bash
sudo ./install_pi.sh ./raspberry-pi-host ./geoteleport-device-core
```

The installer creates `/etc/geoteleport.env` with:

```text
GEOTELEPORT_BIND=0.0.0.0
GEOTELEPORT_PORT=8080
GEOTELEPORT_TOKEN=<generated-token>
GEOTELEPORT_DEVICE_CORE=/opt/geoteleport/geoteleport-device-core
```

Open `http://<pi-address>:8080` from a browser on the same network and enter the token shown by the installer. The systemd service runs as the dedicated `geoteleport` system user, with `plugdev` as a supplementary group when that group exists.

## API

- `GET /api/health`
- `GET /api/devices`
- `GET /api/device/:udid`
- `GET /api/diagnostics`
- `POST /api/pair`
- `POST /api/location` with `{ "udid": "...", "lat": 37.3349, "lon": -122.0090 }`
- `DELETE /api/location/:udid`

When `GEOTELEPORT_TOKEN` is set, API calls must include `x-geoteleport-token: <token>` or `Authorization: Bearer <token>`.

## Remaining Work

- Run a hardware smoke test on Raspberry Pi OS 64-bit with iOS 16, iPadOS 18, and iOS 26 devices.
- Add an automated DeveloperDiskImage mounting flow for iOS 17+ when the DVT service is not advertised.

## Security & Network

The API listens on HTTP by default (`GEOTELEPORT_BIND=0.0.0.0`). To enable HTTPS on the LAN UI, you can provide the certificate and key via environment variables:

```bash
GEOTELEPORT_TLS_CERT=/path/to/cert.pem
GEOTELEPORT_TLS_KEY=/path/to/key.pem
```

When both are provided, the server will bind to HTTPS instead of HTTP.
