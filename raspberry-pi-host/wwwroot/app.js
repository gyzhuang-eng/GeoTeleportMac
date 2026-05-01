const state = {
  devices: [],
  selectedUdid: null,
};

const el = {
  refresh: document.querySelector("#refresh"),
  diagnostics: document.querySelector("#diagnostics"),
  token: document.querySelector("#token"),
  devices: document.querySelector("#devices"),
  pair: document.querySelector("#pair"),
  deviceCount: document.querySelector("#device-count"),
  deviceName: document.querySelector("#device-name"),
  deviceVersion: document.querySelector("#device-version"),
  deviceUdid: document.querySelector("#device-udid"),
  status: document.querySelector("#status"),
  lat: document.querySelector("#lat"),
  lon: document.querySelector("#lon"),
  teleport: document.querySelector("#teleport"),
  clear: document.querySelector("#clear"),
  clearLog: document.querySelector("#clear-log"),
  log: document.querySelector("#log"),
};

el.token.value = localStorage.getItem("geoteleportToken") || "";

function setStatus(message) {
  el.status.textContent = message;
}

function log(message) {
  const line = `[${new Date().toLocaleTimeString()}] ${message}`;
  el.log.textContent = `${line}\n${el.log.textContent}`.slice(0, 6000);
}

async function api(path, options = {}) {
  const headers = new Headers(options.headers || {});
  const token = el.token.value.trim();
  if (token) {
    headers.set("x-geoteleport-token", token);
  }
  if (options.body && !headers.has("content-type")) {
    headers.set("content-type", "application/json");
  }

  const response = await fetch(path, { ...options, headers });
  const text = await response.text();
  const payload = text ? JSON.parse(text) : null;
  if (!response.ok || payload?.status === "error") {
    throw new Error(payload?.error || `HTTP ${response.status}`);
  }
  return payload;
}

function selectedDevice() {
  return state.devices.find((device) => device.identifier === state.selectedUdid) || null;
}

function renderDevices() {
  el.devices.replaceChildren();
  for (const device of state.devices) {
    const option = document.createElement("option");
    option.value = device.identifier;
    option.textContent = device.name || device.identifier;
    el.devices.append(option);
  }

  el.deviceCount.textContent = `${state.devices.length} connected`;
  if (!state.devices.some((device) => device.identifier === state.selectedUdid)) {
    state.selectedUdid = state.devices[0]?.identifier || null;
  }
  el.devices.value = state.selectedUdid || "";
  renderDeviceDetails();
}

function renderDeviceDetails(info = null) {
  const device = selectedDevice();
  el.deviceName.textContent = info?.deviceName || device?.name || "-";
  el.deviceVersion.textContent =
    info?.productVersion || device?.operatingSystemVersion || "-";
  el.deviceUdid.textContent = state.selectedUdid || "-";
  const hasDevice = Boolean(state.selectedUdid);
  el.teleport.disabled = !hasDevice;
  el.clear.disabled = !hasDevice;
}

function logCommand(label, command) {
  const status = command.ok ? "ok" : "failed";
  const stdout = command.stdout ? ` stdout: ${command.stdout}` : "";
  const stderr = command.stderr ? ` stderr: ${command.stderr}` : "";
  const error = command.error ? ` error: ${command.error}` : "";
  log(`${label}: ${status}.${stdout}${stderr}${error}`);
}

async function refreshDevices() {
  setStatus("Refreshing");
  state.devices = await api("/api/devices");
  renderDevices();
  log(`Found ${state.devices.length} USB iOS device(s)`);
  if (state.selectedUdid) {
    await loadDeviceInfo(state.selectedUdid);
  }
  setStatus("Idle");
}

async function loadDeviceInfo(udid) {
  const info = await api(`/api/device/${encodeURIComponent(udid)}`);
  renderDeviceDetails(info);
}

function parseCoordinate(input, label) {
  const value = Number(input.value.trim());
  if (!Number.isFinite(value)) {
    throw new Error(`${label} must be a number`);
  }
  return value;
}

async function setLocation() {
  const udid = state.selectedUdid;
  if (!udid) {
    throw new Error("No device selected");
  }

  const lat = parseCoordinate(el.lat, "Latitude");
  const lon = parseCoordinate(el.lon, "Longitude");
  setStatus("Setting location");
  await api("/api/location", {
    method: "POST",
    body: JSON.stringify({ udid, lat, lon }),
  });
  log(`Set ${udid} to ${lat}, ${lon}`);
  setStatus("Idle");
}

async function clearLocation() {
  const udid = state.selectedUdid;
  if (!udid) {
    throw new Error("No device selected");
  }

  setStatus("Clearing location");
  await api(`/api/location/${encodeURIComponent(udid)}`, { method: "DELETE" });
  log(`Cleared location for ${udid}`);
  setStatus("Idle");
}

async function runDiagnostics() {
  setStatus("Running diagnostics");
  const report = await api("/api/diagnostics");
  log(`Diagnostics: ${report.devices.length} USB iOS device(s) visible`);
  logCommand("usbmuxd", report.commands.usbmuxd);
  logCommand("pairing", report.commands.pairing);
  for (const note of report.notes || []) {
    log(note);
  }
  setStatus("Idle");
}

async function pairDevice() {
  setStatus("Pairing");
  const result = await api("/api/pair", { method: "POST" });
  logCommand("idevicepair pair", result.command);
  await refreshDevices();
  setStatus("Idle");
}

async function run(action) {
  try {
    await action();
  } catch (error) {
    setStatus("Error");
    log(error.message);
  }
}

el.token.addEventListener("input", () => {
  localStorage.setItem("geoteleportToken", el.token.value.trim());
});

el.refresh.addEventListener("click", () => run(refreshDevices));
el.diagnostics.addEventListener("click", () => run(runDiagnostics));
el.pair.addEventListener("click", () => run(pairDevice));

el.devices.addEventListener("change", () => {
  state.selectedUdid = el.devices.value;
  renderDeviceDetails();
  if (state.selectedUdid) {
    run(() => loadDeviceInfo(state.selectedUdid));
  }
});

el.teleport.addEventListener("click", () => run(setLocation));
el.clear.addEventListener("click", () => run(clearLocation));
el.clearLog.addEventListener("click", () => {
  el.log.textContent = "";
});

document.querySelectorAll("[data-lat][data-lon]").forEach((button) => {
  button.addEventListener("click", () => {
    el.lat.value = button.dataset.lat;
    el.lon.value = button.dataset.lon;
  });
});

renderDeviceDetails();
run(refreshDevices);
