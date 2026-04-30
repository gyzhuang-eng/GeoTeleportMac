use idevice::services::lockdown::LockdownClient;
use idevice::services::mobile_image_mounter::ImageMounter;
use idevice::services::simulate_location::LocationSimulationService;
use idevice::usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection, UsbmuxdDevice};
use idevice::IdeviceService;
use serde::{Deserialize, Serialize};
use std::fmt;

// ── Models ──────────────────────────────────────────────────────────

#[derive(Serialize, Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct DeviceEntry {
    pub simulator: bool,
    pub name: String,
    pub identifier: String,
    pub platform: String,
    pub interface: String,
    pub operating_system_version: Option<String>,
}

#[derive(Serialize, Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct DeviceInfo {
    pub udid: String,
    pub device_name: Option<String>,
    pub product_version: Option<String>,
    pub unique_device_id: Option<String>,
    pub device_class: Option<String>,
    pub product_type: Option<String>,
    pub developer_mode_enabled: Option<bool>,
}

#[derive(Serialize, Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct DeveloperModeStatus {
    pub udid: String,
    pub developer_mode_enabled: bool,
}

#[derive(Serialize, Deserialize, Debug)]
#[serde(rename_all = "lowercase")]
pub enum CommandStatus {
    Ok,
    Error,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct StatusResponse {
    pub status: CommandStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

// ── Shared core logic ───────────────────────────────────────────────

pub async fn enumerate_ios_devices_core() -> Result<String, String> {
    let mut connection = match UsbmuxdConnection::default().await {
        Ok(connection) => connection,
        Err(error) if is_empty_enumeration_error(&error.to_string()) => {
            return Ok("[]".to_string());
        }
        Err(error) => return Err(format!("failed to connect to usbmuxd: {}", format_error(error))),
    };

    let devices = match connection.get_devices().await {
        Ok(devices) => devices,
        Err(error) if is_empty_enumeration_error(&error.to_string()) => {
            return Ok("[]".to_string());
        }
        Err(error) => return Err(format!("failed to enumerate iOS devices: {}", format_error(error))),
    };

    let usb_devices: Vec<DeviceEntry> = devices
        .into_iter()
        .filter(|d| matches!(d.connection_type, Connection::Usb))
        .map(|device| DeviceEntry {
            simulator: false,
            name: device.udid.clone(),
            identifier: device.udid,
            platform: "com.apple.platform.iphoneos".to_string(),
            interface: "usb".to_string(),
            operating_system_version: None,
        })
        .collect();

    serde_json::to_string(&usb_devices).map_err(|e| format!("failed to serialize devices: {e}"))
}

pub async fn device_info_core(udid: &str) -> Result<String, String> {
    let device = find_usb_device(udid).await?;

    let connection = UsbmuxdConnection::default()
        .await
        .map_err(|e| format!("failed to connect to usbmuxd: {}", format_error(e)))?;

    let idevice = connection
        .connect_to_device(
            device.device_id,
            LockdownClient::LOCKDOWND_PORT,
            "geoteleport",
        )
        .await
        .map_err(|e| format!("failed to connect to lockdown service: {}", format_error(e)))?;

    let mut lockdown = LockdownClient::new(idevice);

    let info = DeviceInfo {
        udid: udid.to_string(),
        device_name: lockdown_string(&mut lockdown, "DeviceName").await,
        product_version: lockdown_string(&mut lockdown, "ProductVersion").await,
        unique_device_id: lockdown_string(&mut lockdown, "UniqueDeviceID").await,
        device_class: lockdown_string(&mut lockdown, "DeviceClass").await,
        product_type: lockdown_string(&mut lockdown, "ProductType").await,
        developer_mode_enabled: query_developer_mode_status_for_device(&device).await.ok(),
    };

    serde_json::to_string(&info).map_err(|e| format!("failed to serialize device info: {e}"))
}

pub async fn developer_mode_status_core(udid: &str) -> Result<String, String> {
    let developer_mode_enabled = developer_mode_status_value(udid).await?;
    serde_json::to_string(&DeveloperModeStatus {
        udid: udid.to_string(),
        developer_mode_enabled,
    })
    .map_err(|e| format!("failed to serialize developer mode status: {e}"))
}

pub async fn developer_mode_status_value(udid: &str) -> Result<bool, String> {
    let device = find_usb_device(udid).await?;
    query_developer_mode_status_for_device(&device).await
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

    serde_json::to_string(&StatusResponse {
        status: CommandStatus::Ok,
        error: None,
    })
    .map_err(|e| format!("failed to serialize status: {e}"))
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

    serde_json::to_string(&StatusResponse {
        status: CommandStatus::Ok,
        error: None,
    })
    .map_err(|e| format!("failed to serialize status: {e}"))
}

// ── Shared helpers ──────────────────────────────────────────────────

pub async fn find_usb_device(udid: &str) -> Result<UsbmuxdDevice, String> {
    let mut connection = UsbmuxdConnection::default()
        .await
        .map_err(|e| format!("failed to connect to usbmuxd: {}", format_error(e)))?;

    let devices = connection
        .get_devices()
        .await
        .map_err(|e| format!("failed to enumerate iOS devices: {}", format_error(e)))?;

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

async fn query_developer_mode_status_for_device(device: &UsbmuxdDevice) -> Result<bool, String> {
    let provider = device.to_provider(UsbmuxdAddr::default(), "geoteleport");
    let mut mounter = ImageMounter::connect(&provider)
        .await
        .map_err(|e| format!("failed to connect to mobile image mounter: {}", format_error(e)))?;
    mounter
        .query_developer_mode_status()
        .await
        .map_err(|e| format!("failed to query Developer Mode status: {}", format_error(e)))
}

fn is_empty_enumeration_error(message: &str) -> bool {
    message.contains("device socket io failed") || message.contains("Connection refused")
}

fn format_error(error: impl fmt::Display + fmt::Debug) -> String {
    let display = error.to_string();
    let debug = format!("{error:?}");
    if debug == display {
        display
    } else {
        format!("{display} ({debug})")
    }
}
