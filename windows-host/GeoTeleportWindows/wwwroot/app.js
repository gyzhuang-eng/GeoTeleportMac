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
  if (!device) return "未检测到 USB iPhone。";
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

function localizeError(message) {
  return String(message || "未知错误")
    .replaceAll("native core returned error", "原生核心返回错误")
    .replaceAll("native core returned null", "原生核心返回空结果")
    .replaceAll("failed to connect to usbmuxd", "连接 usbmuxd 失败")
    .replaceAll("failed to enumerate iOS devices", "枚举 iOS 设备失败")
    .replaceAll("failed to connect to lockdown service", "连接 lockdown 服务失败")
    .replaceAll("failed to serialize devices", "序列化设备列表失败")
    .replaceAll("failed to serialize device info", "序列化设备信息失败")
    .replaceAll("failed to serialize status", "序列化状态失败")
    .replaceAll("failed to start location simulation service", "启动定位模拟服务失败")
    .replaceAll("failed to set location", "设置定位失败")
    .replaceAll("failed to clear location", "清除定位失败")
    .replaceAll("invalid latitude", "纬度无效")
    .replaceAll("invalid longitude", "经度无效")
    .replaceAll("invalid coordinates", "坐标无效")
    .replaceAll("set-location requires ios17-location-daemon", "设置定位需要 ios17-location-daemon")
    .replaceAll("clear-location requires ios17-location-daemon", "清除定位需要 ios17-location-daemon")
    .replaceAll("device with UDID", "设备 UDID")
    .replaceAll("not found over USB", "未通过 USB 找到")
    .replaceAll("detected", "已检测到");
}

function assertCoreOk(result) {
  let payload = null;
  try {
    payload = JSON.parse(result);
  } catch {
    return;
  }

  if (payload?.status === "error") {
    throw new Error(localizeError(payload.error || "原生核心返回错误"));
  }
}

function coreResultText(result) {
  try {
    const payload = JSON.parse(result);
    if (payload?.status === "ok") return "成功";
    if (payload?.status === "error") return `失败：${localizeError(payload.error)}`;
  } catch {
  }
  return result || "完成";
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
  elements.hardwareTitle.textContent = hasDevice ? "已连接 iPhone" : "未连接设备";
  elements.hardwareTitle.style.color = hasDevice ? "var(--green)" : "var(--red)";
  elements.hardwareSubtitle.textContent = hasDevice
    ? `${selectedDeviceLabel(device)} - ${device.identifier}`
    : "请通过 USB 连接并信任这台电脑。";

  elements.envDot.className = "status-dot";
  if (!state.bridgeAvailable) {
    elements.envText.textContent = "环境：不可用";
  } else if (hasDevice) {
    elements.envDot.classList.add("ready");
    elements.envText.textContent = "环境：就绪";
  } else {
    elements.envDot.classList.add("warn");
    elements.envText.textContent = "环境：设备探测";
  }

  elements.multiDeviceCard.classList.toggle("hidden", state.devices.length < 2);
  elements.multiDeviceTitle.textContent = `已连接 ${state.devices.length} 台 iPhone`;

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
      title: "设备后端不可用",
      subtitle: "WebView 桥接未就绪。请运行打包后的 Windows 程序。",
    };
  }
  if (!state.selectedDeviceId) {
    return {
      kind: "error",
      icon: "⌁",
      title: "请连接 iPhone",
      subtitle: "通过 USB 接入设备，并在 iPhone 上信任这台电脑。",
    };
  }
  if (!coords.latValid || !coords.lonValid) {
    return {
      kind: "warning",
      icon: "!",
      title: "坐标无效",
      subtitle: "纬度范围必须是 -90 到 90，经度范围必须是 -180 到 180。",
    };
  }
  return {
    kind: "ready",
    icon: "✓",
    title: "已准备好修改定位",
    subtitle: "拖动地图、搜索城市，或点击预设地点。",
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
    elements.setButton.textContent = "正在执行...";
  } else if (!state.bridgeAvailable) {
    elements.setButton.textContent = "后端不可用";
  } else if (!state.selectedDeviceId) {
    elements.setButton.textContent = "等待 USB 设备...";
  } else if (!coords.latValid || !coords.lonValid) {
    elements.setButton.textContent = "坐标无效";
  } else {
    elements.setButton.textContent = ">>> 确认并跳转 <<<";
  }

  elements.clearButton.textContent = state.isWorking ? "处理中..." : "⌧ 清除";
}

function renderLogPanel() {
  elements.logPanel.classList.toggle("hidden", !state.logOpen);
  elements.logToggle.textContent = state.logOpen ? "日志 ▾" : "日志 ▴";
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
    option.textContent = "未检测到 USB iPhone。";
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
  setStatus("working", "正在刷新会话...", "正在检查 USB 设备状态");

  const bridge = await getBridge();
  state.bridgeAvailable = Boolean(bridge);
  if (!bridge) {
    state.devices = [];
    replaceDeviceOptions([]);
    log("[系统] WebView 桥接不可用。");
    setStatus("idle", "", "");
    return;
  }

  try {
    const json = await bridge.EnumerateDevices();
    const devices = JSON.parse(json) || [];
    state.devices = devices.filter((device) => !device.simulator);
    replaceDeviceOptions(state.devices);

    if (state.devices.length === 0) {
      log("[硬件] 未检测到 USB iPhone。");
    } else {
      log(`[硬件] 检测到 ${state.devices.length} 台 USB iPhone。`);
      const device = selectedDevice();
      if (device) {
        log(`[设备] 已选择 ${selectedDeviceLabel(device)} (${device.identifier})`);
      }
    }
    setStatus("idle", "", "");
  } catch (error) {
    state.devices = [];
    replaceDeviceOptions([]);
    const message = localizeError(error.message);
    log(`[系统] 枚举设备失败：${message}`);
    setStatus("error", "设备刷新失败", message);
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
    log("[设备] 设备信息：");
    log(`[设备] 名称：${info.device_name || "未知"}`);
    log(`[设备] iOS：${info.product_version || "未知"}`);
    log(`[设备] 型号：${info.product_type || "未知"}`);
    log(`[设备] UDID：${info.udid || deviceId}`);
  } catch (error) {
    log(`[设备] 获取信息失败：${localizeError(error.message)}`);
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

  setStatus("working", "正在搜索城市...", query);
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
      log(`[搜索] 没有找到：${query}`);
      setStatus("warning", "未找到城市", query);
      return;
    }

    const lat = Number.parseFloat(results[0].lat);
    const lon = Number.parseFloat(results[0].lon);
    setMapCenter(lat, lon, 14);
    log(`[搜索] ${query} -> ${formatCoordinate(lat)}, ${formatCoordinate(lon)}`);
    setStatus("idle", "", "");
  } catch (error) {
    log(`[搜索] 失败：${localizeError(error.message)}`);
    setStatus("error", "搜索失败", "请检查网络连接后重试。");
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
  setStatus("working", "正在修改定位...", `${formatCoordinate(coords.lat)}, ${formatCoordinate(coords.lon)}`);
  log("[用户] 点击执行跳转");
  log("[核心] 已锁定目标坐标");
  log(`[数据] 纬度：${formatCoordinate(coords.lat)}`);
  log(`[数据] 经度：${formatCoordinate(coords.lon)}`);
  log("[核心] 正在启动注入流程...");

  try {
    const result = await bridge.SetLocation(
      state.selectedDeviceId,
      formatCoordinate(coords.lat),
      formatCoordinate(coords.lon),
    );
    assertCoreOk(result);
    log(`[核心] ${coreResultText(result)}`);
    setStatus("success", "GPS 已移动", `${formatCoordinate(coords.lat)}, ${formatCoordinate(coords.lon)}`);
  } catch (error) {
    const message = localizeError(error.message);
    log(`[核心] 设置失败：${message}`);
    setStatus("error", "修改定位失败", message);
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
  setStatus("working", "正在清除定位...", "正在请求恢复真实 GPS");
  log("[用户] 点击清除定位");
  log("[核心] 正在恢复设备真实定位...");

  try {
    const result = await bridge.ClearLocation(state.selectedDeviceId);
    assertCoreOk(result);
    log(`[核心] ${coreResultText(result)}`);
    setStatus("success", "GPS 已恢复", "设备真实定位已恢复");
  } catch (error) {
    const message = localizeError(error.message);
    log(`[核心] 清除失败：${message}`);
    setStatus("error", "清除失败", message);
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
  if (device) log(`[设备] 已选择 ${selectedDeviceLabel(device)} (${device.identifier})`);
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
    log(`[用户] 已选择预设：${button.dataset.name}`);
  });
});

map.on("moveend", () => {
  if (state.suppressMapSync) return;
  const center = map.getCenter();
  setInputsFromLatLng(center.lat, center.lng);
});

window.addEventListener("DOMContentLoaded", () => {
  log("[系统] 正在初始化 GeoTeleport Windows版...");
  log(`[系统] 浏览器内核：${navigator.userAgent}`);
  render();
  window.setTimeout(refreshDevices, 300);
});
