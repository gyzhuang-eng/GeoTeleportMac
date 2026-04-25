use idevice::services::lockdown::LockdownClient;
use idevice::services::simulate_location::LocationSimulationService;
use idevice::usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection, UsbmuxdDevice};
use idevice::IdeviceService;

// ── Shared core logic ───────────────────────────────────────────────

pub async fn enumerate_ios_devices_core() -> Result<String, String> {
    let mut connection = UsbmuxdConnection::default()
        .await
        .map_err(|e| format!("failed to connect to usbmuxd: {e}"))?;

    let devices = connection
        .get_devices()
        .await
        .map_err(|e| format!("failed to enumerate iOS devices: {e}"))?;

    let usb_devices: Vec<String> = devices
        .into_iter()
        .filter(|d| matches!(d.connection_type, Connection::Usb))
        .map(|device| {
            format!(
                concat!(
                    r#"{{"simulator":false,"name":"{}","identifier":"{}","#,
                    r#""platform":"com.apple.platform.iphoneos","interface":"usb","#,
                    r#""operatingSystemVersion":null}}"#
                ),
                device.udid, device.udid
            )
        })
        .collect();

    Ok(format!("[{}]", usb_devices.join(",")))
}

pub async fn device_info_core(udid: &str) -> Result<String, String> {
    let device = find_usb_device(udid).await?;

    let connection = UsbmuxdConnection::default()
        .await
        .map_err(|e| format!("failed to connect to usbmuxd: {e}"))?;

    let idevice = connection
        .connect_to_device(device.device_id, LockdownClient::LOCKDOWND_PORT, "geoteleport")
        .await
        .map_err(|e| format!("failed to connect to lockdown service: {e}"))?;

    let mut lockdown = LockdownClient::new(idevice);

    let device_name = lockdown_string(&mut lockdown, "DeviceName").await;
    let product_version = lockdown_string(&mut lockdown, "ProductVersion").await;
    let unique_device_id = lockdown_string(&mut lockdown, "UniqueDeviceID").await;
    let device_class = lockdown_string(&mut lockdown, "DeviceClass").await;
    let product_type = lockdown_string(&mut lockdown, "ProductType").await;

    Ok(format!(
        concat!(
            r#"{{"udid":{},"deviceName":{},"productVersion":{},"#,
            r#""uniqueDeviceID":{},"deviceClass":{},"productType":{}}}"#
        ),
        json_str(udid),
        json_opt(device_name.as_deref()),
        json_opt(product_version.as_deref()),
        json_opt(unique_device_id.as_deref()),
        json_opt(device_class.as_deref()),
        json_opt(product_type.as_deref()),
    ))
}

pub async fn set_location_core(udid: &str, lat: f64, lon: f64) -> Result<String, String> {
    let device = find_usb_device(udid).await?;

    if let Some(major) = get_ios_major(device.device_id).await {
        if major >= 17 {
            return Err(format!(
                "iOS {major} detected: set-location requires ios17-location-daemon (TEMPORARY_LIMITATION)"
            ));
        }
    }

    let provider = device.to_provider(UsbmuxdAddr::default(), "geoteleport");
    let mut service = LocationSimulationService::connect(&provider)
        .await
        .map_err(|e| format!("failed to start location simulation service: {e}"))?;

    service
        .set(&lat.to_string(), &lon.to_string())
        .await
        .map_err(|e| format!("failed to set location: {e}"))?;

    Ok("{\"status\":\"ok\"}".to_string())
}

pub async fn clear_location_core(udid: &str) -> Result<String, String> {
    let device = find_usb_device(udid).await?;

    if let Some(major) = get_ios_major(device.device_id).await {
        if major >= 17 {
            return Err(format!(
                "iOS {major} detected: clear-location requires ios17-location-daemon (TEMPORARY_LIMITATION)"
            ));
        }
    }

    let provider = device.to_provider(UsbmuxdAddr::default(), "geoteleport");
    let mut service = LocationSimulationService::connect(&provider)
        .await
        .map_err(|e| format!("failed to start location simulation service: {e}"))?;

    service
        .clear()
        .await
        .map_err(|e| format!("failed to clear location: {e}"))?;

    Ok("{\"status\":\"ok\"}".to_string())
}

// ── Shared helpers ──────────────────────────────────────────────────

pub async fn find_usb_device(udid: &str) -> Result<UsbmuxdDevice, String> {
    let mut connection = UsbmuxdConnection::default()
        .await
        .map_err(|e| format!("failed to connect to usbmuxd: {e}"))?;

    let devices = connection
        .get_devices()
        .await
        .map_err(|e| format!("failed to enumerate iOS devices: {e}"))?;

    devices
        .into_iter()
        .find(|d| d.udid == udid && matches!(d.connection_type, Connection::Usb))
        .ok_or_else(|| format!("device with UDID {udid} not found over USB"))
}

pub async fn get_ios_major(device_id: u32) -> Option<u32> {
    let connection = UsbmuxdConnection::default().await.ok()?;
    let idevice = connection
        .connect_to_device(device_id, LockdownClient::LOCKDOWND_PORT, "geoteleport")
        .await
        .ok()?;
    let mut lockdown = LockdownClient::new(idevice);
    let version = lockdown_string(&mut lockdown, "ProductVersion").await?;
    version.split('.').next()?.parse::<u32>().ok()
}

pub async fn lockdown_string(lockdown: &mut LockdownClient, key: &str) -> Option<String> {
    lockdown
        .get_value(Some(key), None)
        .await
        .ok()
        .and_then(|v| v.as_string().map(|s| s.to_owned()))
}

pub fn json_str(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}

pub fn json_opt(s: Option<&str>) -> String {
    match s {
        Some(s) => json_str(s),
        None => "null".to_owned(),
    }
}
