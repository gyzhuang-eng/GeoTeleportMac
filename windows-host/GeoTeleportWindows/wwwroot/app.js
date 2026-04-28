const map = L.map('map', { zoomControl: false }).setView([37.334900, -122.009020], 13);

L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
  maxZoom: 19,
  attribution: '© OpenStreetMap'
}).addTo(map);

// Add zoom control to bottom right instead of top left
L.control.zoom({ position: 'bottomright' }).addTo(map);

// Map marker
let marker = L.marker([37.334900, -122.009020]).addTo(map);

const deviceSelect = document.getElementById('device-select');
const latInput = document.getElementById('lat-input');
const lonInput = document.getElementById('lon-input');
const statusText = document.getElementById('status-text');
const logContent = document.getElementById('log-content');

function log(msg) {
  const time = new Date().toLocaleTimeString();
  const line = `[${time}] ${msg}\n`;
  logContent.textContent += line;
  logContent.scrollTop = logContent.scrollHeight;
}

function setStatus(msg, isError = false) {
  statusText.textContent = msg;
  statusText.style.color = isError ? '#ff453a' : 'rgba(255, 255, 255, 0.7)';
}

async function getBridge() {
  if (window.chrome && window.chrome.webview && window.chrome.webview.hostObjects) {
    return window.chrome.webview.hostObjects.bridge;
  }
  return null;
}

async function refreshDevices() {
  setStatus('Refreshing devices...');
  const bridge = await getBridge();
  if (!bridge) {
    log('Bridge not found. Running in browser?');
    setStatus('Bridge error', true);
    return;
  }

  try {
    const json = await bridge.EnumerateDevices();
    const devices = JSON.parse(json);
    
    deviceSelect.innerHTML = '';
    if (!devices || devices.length === 0) {
      deviceSelect.innerHTML = '<option value="">No USB iPhone detected.</option>';
      log('No USB iPhone detected.');
    } else {
      for (const dev of devices) {
        const opt = document.createElement('option');
        opt.value = dev.identifier;
        opt.textContent = `${dev.name} - ${dev.identifier}`;
        deviceSelect.appendChild(opt);
      }
      log(`Detected ${devices.length} USB device(s).`);
    }
    setStatus('Ready');
  } catch (err) {
    log(`Enumerate failed: ${err.message}`);
    setStatus('Refresh failed', true);
  }
}

async function loadDeviceInfo() {
  const udid = deviceSelect.value;
  if (!udid) {
    log('Select a USB device first.');
    return;
  }

  setStatus('Fetching info...');
  const bridge = await getBridge();
  try {
    const json = await bridge.DeviceInfo(udid);
    const info = JSON.parse(json);
    log('Device info:');
    log(`  Name: ${info.device_name || '(unknown)'}`);
    log(`  iOS: ${info.product_version || '(unknown)'}`);
    log(`  Type: ${info.product_type || '(unknown)'}`);
    log(`  UDID: ${info.udid || udid}`);
    setStatus('Ready');
  } catch (err) {
    log(`Info failed: ${err.message}`);
    setStatus('Info failed', true);
  }
}

async function setLocation() {
  const udid = deviceSelect.value;
  if (!udid) {
    log('Select a USB device first.');
    return;
  }

  const lat = parseFloat(latInput.value);
  const lon = parseFloat(lonInput.value);
  if (isNaN(lat) || isNaN(lon)) {
    log('Invalid coordinates.');
    return;
  }

  setStatus('Setting location...');
  // Update map marker
  marker.setLatLng([lat, lon]);
  map.setView([lat, lon], 15);

  const bridge = await getBridge();
  try {
    const res = await bridge.SetLocation(udid, lat.toString(), lon.toString());
    log(`Set result: ${res}`);
    setStatus('Location set');
  } catch (err) {
    log(`Set failed: ${err.message}`);
    setStatus('Set failed', true);
  }
}

async function clearLocation() {
  const udid = deviceSelect.value;
  if (!udid) {
    log('Select a USB device first.');
    return;
  }

  setStatus('Clearing location...');
  const bridge = await getBridge();
  try {
    const res = await bridge.ClearLocation(udid);
    log(`Clear result: ${res}`);
    setStatus('Location cleared');
  } catch (err) {
    log(`Clear failed: ${err.message}`);
    setStatus('Clear failed', true);
  }
}

// Event Listeners
document.getElementById('refresh-btn').addEventListener('click', refreshDevices);
document.getElementById('info-btn').addEventListener('click', loadDeviceInfo);
document.getElementById('set-btn').addEventListener('click', setLocation);
document.getElementById('clear-btn').addEventListener('click', clearLocation);

document.getElementById('export-btn').addEventListener('click', async () => {
  const bridge = await getBridge();
  if (bridge) {
    const udid = deviceSelect.value;
    await bridge.ExportDiagnostics(udid || '', logContent.textContent);
  }
});

document.getElementById('clear-log-btn').addEventListener('click', () => {
  logContent.textContent = '';
});

// Update map on input change
function updateMapFromInputs() {
  const lat = parseFloat(latInput.value);
  const lon = parseFloat(lonInput.value);
  if (!isNaN(lat) && !isNaN(lon)) {
    marker.setLatLng([lat, lon]);
    map.setView([lat, lon]);
  }
}
latInput.addEventListener('change', updateMapFromInputs);
lonInput.addEventListener('change', updateMapFromInputs);

// Presets
document.querySelectorAll('.preset-btn').forEach(btn => {
  btn.addEventListener('click', () => {
    latInput.value = btn.dataset.lat;
    lonInput.value = btn.dataset.lon;
    updateMapFromInputs();
  });
});

// Click on map to set inputs
map.on('click', (e) => {
  latInput.value = e.latlng.lat.toFixed(6);
  lonInput.value = e.latlng.lng.toFixed(6);
  updateMapFromInputs();
});

// Init
window.addEventListener('DOMContentLoaded', () => {
  log('Initializing GeoTeleport Windows...');
  // Wait a small delay to ensure bridge is injected
  setTimeout(refreshDevices, 300);
});
