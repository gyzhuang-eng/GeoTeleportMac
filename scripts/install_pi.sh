#!/usr/bin/env bash
set -euo pipefail

HOST_SOURCE_BINARY="${1:-./raspberry-pi-host}"
CORE_SOURCE_BINARY="${2:-./geoteleport-device-core}"
APP_DIR="/opt/geoteleport"
APP_BIN="${APP_DIR}/geoteleport-host"
CORE_BIN="${APP_DIR}/geoteleport-device-core"
ENV_FILE="/etc/geoteleport.env"
SERVICE_FILE="/etc/systemd/system/geoteleport.service"
SERVICE_USER="geoteleport"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this installer with sudo." >&2
  exit 1
fi

if [[ ! -f "${HOST_SOURCE_BINARY}" ]]; then
  echo "Host binary not found: ${HOST_SOURCE_BINARY}" >&2
  exit 1
fi

if [[ ! -f "${CORE_SOURCE_BINARY}" ]]; then
  echo "Device-core binary not found: ${CORE_SOURCE_BINARY}" >&2
  echo "Usage: sudo $0 ./raspberry-pi-host ./geoteleport-device-core" >&2
  exit 1
fi

apt-get update
apt-get install -y usbmuxd libimobiledevice-utils curl

if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
  useradd --system --home-dir "${APP_DIR}" --shell /usr/sbin/nologin "${SERVICE_USER}"
fi
if getent group plugdev >/dev/null; then
  usermod -a -G plugdev "${SERVICE_USER}" || true
  SUPPLEMENTARY_GROUPS="SupplementaryGroups=plugdev"
else
  SUPPLEMENTARY_GROUPS=""
fi

install -d -m 0755 "${APP_DIR}"
install -m 0755 "${HOST_SOURCE_BINARY}" "${APP_BIN}"
install -m 0755 "${CORE_SOURCE_BINARY}" "${CORE_BIN}"
chown -R "${SERVICE_USER}:${SERVICE_USER}" "${APP_DIR}"

TOKEN="${GEOTELEPORT_TOKEN:-}"
if [[ -z "${TOKEN}" ]]; then
  TOKEN="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
fi

cat >"${ENV_FILE}" <<EOF
GEOTELEPORT_BIND=0.0.0.0
GEOTELEPORT_PORT=8080
GEOTELEPORT_TOKEN=${TOKEN}
GEOTELEPORT_DEVICE_CORE=${CORE_BIN}
# To enable HTTPS, provide the paths to the certificate and key files
# GEOTELEPORT_TLS_CERT=/etc/geoteleport/cert.pem
# GEOTELEPORT_TLS_KEY=/etc/geoteleport/key.pem
EOF
chown "root:${SERVICE_USER}" "${ENV_FILE}"
chmod 0640 "${ENV_FILE}"

cat >"${SERVICE_FILE}" <<EOF
[Unit]
Description=GeoTeleport Raspberry Pi Host
After=network-online.target usbmuxd.service
Wants=network-online.target
Requires=usbmuxd.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
${SUPPLEMENTARY_GROUPS}
EnvironmentFile=${ENV_FILE}
ExecStart=${APP_BIN}
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now geoteleport.service

ADDRESS="$(hostname -I | awk '{print $1}')"
echo "GeoTeleport Pi host is installed."
echo "Open: http://${ADDRESS:-raspberrypi.local}:8080"
echo "Token: ${TOKEN}"
