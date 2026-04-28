const DEFAULT_LOCATION = {
  lat: 25.185317,
  lon: 55.281516,
  zoom: 15,
};

const MAX_LOG_LINES = 400;

const map = L.map("map", {
  zoomControl: false,
  attributionControl: true,
}).setView([DEFAULT_LOCATION.lat, DEFAULT_LOCATION.lon], DEFAULT_LOCATION.zoom);

L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
  maxZoom: 19,
  attribution: "© OpenStreetMap",
}).addTo(map);

L.control.zoom({ position: "bottomright" }).addTo(map);

const elements = {
  deviceIcon: document.getElementById("device-icon"),
  hardwareTitle: document.getElementById("hardware-title"),
  hardwareSubtitle: document.getElementById("hardware-subtitle"),
  envDot: document.getElementById("env-dot"),
  envText: document.getElementById("env-text"),
  deviceSelect: document.getElementById("device-select"),
  multiDeviceCard: document.getElementById("multi-device-card"),
  multiDeviceTitle: document.getElementById("multi-device-title"),
  cityInput: document.getElementById("city-input"),
  latInput: document.getElementById("lat-input"),
  lonInput: document.getElementById("lon-input"),
  latField: document.getElementById("lat-field"),
  lonField: document.getElementById("lon-field"),
  setButton: document.getElementById("set-btn"),
  clearButton: document.getElementById("clear-btn"),
  statusCard: document.getElementById("status-card"),
  statusIcon: document.getElementById("status-icon"),
  statusTitle: document.getElementById("status-title"),
  statusSubtitle: document.getElementById("status-subtitle"),
  logToggle: document.getElementById("log-toggle"),
  logPanel: document.getElementById("log-panel"),
  logContent: document.getElementById("log-content"),
  logCount: document.getElementById("log-count"),
};

const state = {
  bridgeAvailable: false,
  devices: [],
  selectedDeviceId: "",
  isWorking: false,
  statusKind: "idle",
  statusTitle: "",
  statusSubtitle: "",
  logOpen: false,
  logLines: [],
  suppressMapSync: false,
};

function formatCoordinate(value) {
  return Number(value).toFixed(6);
}

function parseCoordinates() {
  const lat = Number.parseFloat(elements.latInput.value);
  const lon = Number.parseFloat(elements.lonInput.value);
  return {
    lat,
    lon,
    latValid: Number.isFinite(lat) && lat >= -90 && lat <= 90,
    lonValid: Number.isFinite(lon) && lon >= -180 && lon <= 180,
  };
}

function selectedDevice() {
  return state.devices.find((device) => device.identifier === state.selectedDeviceId) ?? null;
}

function selectedDeviceLabel(device) {
  if (!device) return "No USB iPhone detected.";
  const version = device.operatingSystemVersion ? ` iOS ${device.operatingSystemVersion}` : "";
  return `${device.name || "iPhone"}${version}`;
}

function canTeleport() {
  const coords = parseCoordinates();
  return state.bridgeAvailable && !state.isWorking && Boolean(state.selectedDeviceId) && coords.latValid && coords.lonValid;
}

function canClearLocation() {
  return state.bridgeAvailable && !state.isWorking && Boolean(state.selectedDeviceId);
}

function log(message) {
  const time = new Date().toLocaleTimeString();
  state.logLines.push(`[${time}] ${message}`);
  if (state.logLines.length > MAX_LOG_LINES) {
    state.logLines.splice(0, state.logLines.length - MAX_LOG_LINES);
  }
  elements.logContent.textContent = state.logLines.join("\n");
  elements.logCount.textContent = `${state.logLines.length}/${MAX_LOG_LINES}`;
  elements.logContent.scrollTop = elements.logContent.scrollHeight;
}

function setStatus(kind, title, subtitle = "") {
  state.statusKind = kind;
  state.statusTitle = title;
  state.statusSubtitle = subtitle;
  render();
}

function assertCoreOk(result) {
  let payload = null;
  try {
    payload = JSON.parse(result);
  } catch {
    return;
  }

  if (payload?.status === "error") {
    throw new Error(payload.error || "native core returned error");
  }
}

function clearTransientSuccess() {
  if (state.statusKind === "success") {
    setStatus("idle", "", "");
  }
}

function renderDeviceState() {
  const device = selectedDevice();
  const hasDevice = Boolean(device);

  elements.deviceIcon.classList.toggle("connected", hasDevice);
  elements.deviceIcon.textContent = hasDevice ? "▣" : "⌁";
  elements.hardwareTitle.textContent = hasDevice ? "IPHONE CONNECTED" : "NO DEVICE";
  elements.hardwareTitle.style.color = hasDevice ? "var(--green)" : "var(--red)";
  elements.hardwareSubtitle.textContent = hasDevice
    ? `${selectedDeviceLabel(device)} - ${device.identifier}`
    : "Plug in via USB and trust this computer.";

  elements.envDot.className = "status-dot";
  if (!state.bridgeAvailable) {
    elements.envText.textContent = "ENV: MISSING";
  } else if (hasDevice) {
    elements.envDot.classList.add("ready");
    elements.envText.textContent = "ENV: READY";
  } else {
    elements.envDot.classList.add("warn");
    elements.envText.textContent = "ENV: DEVICE PROBE";
  }

  elements.multiDeviceCard.classList.toggle("hidden", state.devices.length < 2);
  elements.multiDeviceTitle.textContent = `${state.devices.length} iPhones connected`;

  elements.deviceSelect.disabled = state.devices.length === 0;
}

function renderCoordinates() {
  const coords = parseCoordinates();
  elements.latField.classList.toggle("invalid", !coords.latValid);
  elements.lonField.classList.toggle("invalid", !coords.lonValid);
}

function statusDisplay() {
  if (state.statusKind !== "idle") {
    return {
      kind: state.statusKind,
      icon: state.statusKind === "working" ? "↻" : state.statusKind === "success" ? "✓" : "!",
      title: state.statusTitle,
      subtitle: state.statusSubtitle,
    };
  }

  const coords = parseCoordinates();
  if (!state.bridgeAvailable) {
    return {
      kind: "error",
      icon: "!",
      title: "Device backend unavailable",
      subtitle: "WebView bridge is not available. Run the packaged Windows app.",
    };
  }
  if (!state.selectedDeviceId) {
    return {
      kind: "error",
      icon: "⌁",
      title: "Connect your iPhone",
      subtitle: "Plug in via USB and trust this computer on the device.",
    };
  }
  if (!coords.latValid || !coords.lonValid) {
    return {
      kind: "warning",
      icon: "!",
      title: "Invalid coordinates",
      subtitle: "Latitude must be -90...90, longitude must be -180...180.",
    };
  }
  return {
    kind: "ready",
    icon: "✓",
    title: "Ready to teleport",
    subtitle: "Drag the map, search a city, or tap a preset.",
  };
}

function renderStatus() {
  const display = statusDisplay();
  elements.statusCard.className = `status-card ${display.kind}`;
  elements.statusIcon.textContent = display.icon;
  elements.statusTitle.textContent = display.title;
  elements.statusSubtitle.textContent = display.subtitle || "";
}

function renderActions() {
  const coords = parseCoordinates();
  elements.setButton.disabled = !canTeleport();
  elements.clearButton.disabled = !canClearLocation();

  if (state.isWorking) {
    elements.setButton.textContent = "EXECUTING...";
  } else if (!state.bridgeAvailable) {
    elements.setButton.textContent = "BACKEND UNAVAILABLE";
  } else if (!state.selectedDeviceId) {
    elements.setButton.textContent = "WAITING FOR USB...";
  } else if (!coords.latValid || !coords.lonValid) {
    elements.setButton.textContent = "INVALID COORDS";
  } else {
    elements.setButton.textContent = ">>> CONFIRM & JUMP <<<";
  }

  elements.clearButton.textContent = state.isWorking ? "WORKING..." : "⌧ CLEAR";
}

function renderLogPanel() {
  elements.logPanel.classList.toggle("hidden", !state.logOpen);
  elements.logToggle.textContent = state.logOpen ? "Log ▾" : "Log ▴";
}

function render() {
  renderDeviceState();
  renderCoordinates();
  renderStatus();
  renderActions();
  renderLogPanel();
}

async function getBridge() {
  if (window.chrome?.webview?.hostObjects?.bridge) {
    return window.chrome.webview.hostObjects.bridge;
  }
  return null;
}

function replaceDeviceOptions(devices) {
  const previousSelection = state.selectedDeviceId;
  elements.deviceSelect.innerHTML = "";

  if (devices.length === 0) {
    const option = document.createElement("option");
    option.value = "";
    option.textContent = "No USB iPhone detected.";
    elements.deviceSelect.appendChild(option);
    state.selectedDeviceId = "";
    return;
  }

  for (const device of devices) {
    const option = document.createElement("option");
    option.value = device.identifier;
    option.textContent = selectedDeviceLabel(device);
    elements.deviceSelect.appendChild(option);
  }

  state.selectedDeviceId = devices.some((device) => device.identifier === previousSelection)
    ? previousSelection
    : devices[0].identifier;
  elements.deviceSelect.value = state.selectedDeviceId;
}

async function refreshDevices() {
  setStatus("working", "Refreshing session...", "Checking USB device state");

  const bridge = await getBridge();
  state.bridgeAvailable = Boolean(bridge);
  if (!bridge) {
    state.devices = [];
    replaceDeviceOptions([]);
    log("[SYS] WebView bridge unavailable.");
    setStatus("idle", "", "");
    return;
  }

  try {
    const json = await bridge.EnumerateDevices();
    const devices = JSON.parse(json) || [];
    state.devices = devices.filter((device) => !device.simulator);
    replaceDeviceOptions(state.devices);

    if (state.devices.length === 0) {
      log("[HARDWARE] No USB iPhone detected.");
    } else {
      log(`[HARDWARE] ${state.devices.length} USB iPhone(s) detected.`);
      const device = selectedDevice();
      if (device) {
        log(`[DEVICE] Selected ${selectedDeviceLabel(device)} (${device.identifier})`);
      }
    }
    setStatus("idle", "", "");
  } catch (error) {
    state.devices = [];
    replaceDeviceOptions([]);
    log(`[SYS] Enumerate failed: ${error.message}`);
    setStatus("error", "Device refresh failed", error.message);
  }
}

async function loadDeviceInfo() {
  const deviceId = state.selectedDeviceId;
  if (!deviceId) return;

  const bridge = await getBridge();
  if (!bridge) return;

  try {
    const json = await bridge.DeviceInfo(deviceId);
    const info = JSON.parse(json);
    log("[DEVICE] Device info:");
    log(`[DEVICE] Name: ${info.device_name || "(unknown)"}`);
    log(`[DEVICE] iOS: ${info.product_version || "(unknown)"}`);
    log(`[DEVICE] Type: ${info.product_type || "(unknown)"}`);
    log(`[DEVICE] UDID: ${info.udid || deviceId}`);
  } catch (error) {
    log(`[DEVICE] Info failed: ${error.message}`);
  }
}

function setInputsFromLatLng(lat, lon) {
  elements.latInput.value = formatCoordinate(lat);
  elements.lonInput.value = formatCoordinate(lon);
  clearTransientSuccess();
  render();
}

function setMapCenter(lat, lon, zoom = Math.max(map.getZoom(), DEFAULT_LOCATION.zoom)) {
  state.suppressMapSync = true;
  map.setView([lat, lon], zoom, { animate: true });
  setInputsFromLatLng(lat, lon);
  window.setTimeout(() => {
    state.suppressMapSync = false;
  }, 250);
}

function syncMapFromInputs() {
  const coords = parseCoordinates();
  render();
  if (!coords.latValid || !coords.lonValid) return;

  state.suppressMapSync = true;
  map.setView([coords.lat, coords.lon], map.getZoom(), { animate: true });
  clearTransientSuccess();
  window.setTimeout(() => {
    state.suppressMapSync = false;
  }, 250);
}

async function searchCity() {
  const query = elements.cityInput.value.trim();
  if (!query) return;

  setStatus("working", "Searching city...", query);
  try {
    const url = new URL("https://nominatim.openstreetmap.org/search");
    url.searchParams.set("format", "jsonv2");
    url.searchParams.set("limit", "1");
    url.searchParams.set("q", query);

    const response = await fetch(url.toString(), {
      headers: { "Accept": "application/json" },
    });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }

    const results = await response.json();
    if (!results.length) {
      log(`[SEARCH] No result for ${query}`);
      setStatus("warning", "City not found", query);
      return;
    }

    const lat = Number.parseFloat(results[0].lat);
    const lon = Number.parseFloat(results[0].lon);
    setMapCenter(lat, lon, 14);
    log(`[SEARCH] ${query} -> ${formatCoordinate(lat)}, ${formatCoordinate(lon)}`);
    setStatus("idle", "", "");
  } catch (error) {
    log(`[SEARCH] Failed: ${error.message}`);
    setStatus("error", "Search failed", "Check network access and try again.");
  }
}

async function setLocation() {
  if (!canTeleport()) {
    render();
    return;
  }

  const coords = parseCoordinates();
  const bridge = await getBridge();
  if (!bridge) return;

  state.isWorking = true;
  setStatus("working", "Teleporting...", `${formatCoordinate(coords.lat)}, ${formatCoordinate(coords.lon)}`);
  log("[USER] ACTION: EXECUTE JUMP CLICKED");
  log("[KERNEL] TARGET LOCK ACQUIRED");
  log(`[DATA] LATITUDE:  ${formatCoordinate(coords.lat)}`);
  log(`[DATA] LONGITUDE: ${formatCoordinate(coords.lon)}`);
  log("[KERNEL] INITIATING INJECTION SEQUENCE...");

  try {
    const result = await bridge.SetLocation(
      state.selectedDeviceId,
      formatCoordinate(coords.lat),
      formatCoordinate(coords.lon),
    );
    assertCoreOk(result);
    log(`[CORE] ${result}`);
    setStatus("success", "GPS moved", `${formatCoordinate(coords.lat)}, ${formatCoordinate(coords.lon)}`);
  } catch (error) {
    log(`[CORE] Set failed: ${error.message}`);
    setStatus("error", "Teleport failed", error.message);
  } finally {
    state.isWorking = false;
    render();
  }
}

async function clearLocation() {
  if (!canClearLocation()) {
    render();
    return;
  }

  const bridge = await getBridge();
  if (!bridge) return;

  state.isWorking = true;
  setStatus("working", "Clearing location...", "Requesting real GPS restore");
  log("[USER] ACTION: CLEAR LOCATION CLICKED");
  log("[KERNEL] RESTORING REAL DEVICE LOCATION...");

  try {
    const result = await bridge.ClearLocation(state.selectedDeviceId);
    assertCoreOk(result);
    log(`[CORE] ${result}`);
    setStatus("success", "GPS restored", "Real device location resumed");
  } catch (error) {
    log(`[CORE] Clear failed: ${error.message}`);
    setStatus("error", "Clear failed", error.message);
  } finally {
    state.isWorking = false;
    render();
  }
}

document.getElementById("refresh-btn").addEventListener("click", refreshDevices);
document.getElementById("search-btn").addEventListener("click", searchCity);
document.getElementById("clear-search-btn").addEventListener("click", () => {
  elements.cityInput.value = "";
  elements.cityInput.focus();
});
elements.cityInput.addEventListener("keydown", (event) => {
  if (event.key === "Enter") searchCity();
});

elements.deviceSelect.addEventListener("change", () => {
  state.selectedDeviceId = elements.deviceSelect.value;
  const device = selectedDevice();
  if (device) log(`[DEVICE] Selected ${selectedDeviceLabel(device)} (${device.identifier})`);
  render();
  loadDeviceInfo();
});

elements.latInput.addEventListener("change", syncMapFromInputs);
elements.lonInput.addEventListener("change", syncMapFromInputs);
elements.latInput.addEventListener("input", render);
elements.lonInput.addEventListener("input", render);
elements.setButton.addEventListener("click", setLocation);
elements.clearButton.addEventListener("click", clearLocation);
elements.logToggle.addEventListener("click", () => {
  state.logOpen = !state.logOpen;
  renderLogPanel();
});

document.getElementById("export-btn").addEventListener("click", async () => {
  const bridge = await getBridge();
  if (!bridge) return;
  await bridge.ExportDiagnostics(state.selectedDeviceId || "", state.logLines.join("\n"));
});

document.getElementById("clear-log-btn").addEventListener("click", () => {
  state.logLines = [];
  elements.logContent.textContent = "";
  elements.logCount.textContent = `0/${MAX_LOG_LINES}`;
});

document.querySelectorAll(".preset-btn").forEach((button) => {
  button.addEventListener("click", () => {
    const lat = Number.parseFloat(button.dataset.lat);
    const lon = Number.parseFloat(button.dataset.lon);
    setMapCenter(lat, lon, 15);
    log(`[USER] Selected Preset: ${button.dataset.name}`);
  });
});

map.on("moveend", () => {
  if (state.suppressMapSync) return;
  const center = map.getCenter();
  setInputsFromLatLng(center.lat, center.lng);
});

window.addEventListener("DOMContentLoaded", () => {
  log("[SYS] Initializing GeoTeleport Windows...");
  log(`[SYS] User agent: ${navigator.userAgent}`);
  render();
  window.setTimeout(refreshDevices, 300);
});
