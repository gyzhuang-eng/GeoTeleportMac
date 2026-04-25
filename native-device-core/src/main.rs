use idevice::ReadWrite;
use idevice::services::core_device_proxy::CoreDeviceProxy;
use idevice::services::dvt::location_simulation::LocationSimulationClient;
use idevice::services::dvt::remote_server::RemoteServerClient;
use idevice::services::lockdown::LockdownClient;
use idevice::services::rsd::RsdHandshake;
use idevice::services::simulate_location::LocationSimulationService;
use idevice::usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection, UsbmuxdDevice};
use idevice::IdeviceService;
use std::env;
use std::process::ExitCode;
use tokio::io::{AsyncBufReadExt, BufReader};

#[tokio::main]
async fn main() -> ExitCode {
    let mut args = env::args().skip(1);
    match args.next().as_deref() {
        Some("enumerate-ios-devices") => enumerate_ios_devices().await,
        Some("device-info") => match args.next() {
            Some(udid) => device_info(&udid).await,
            None => {
                eprintln!("usage: geoteleport-device-core device-info <udid>");
                ExitCode::from(64)
            }
        },
        Some("set-location") => {
            let udid = args.next();
            let lat = args.next();
            let lon = args.next();
            match (udid, lat, lon) {
                (Some(udid), Some(lat), Some(lon)) => set_location(&udid, &lat, &lon).await,
                _ => {
                    eprintln!("usage: geoteleport-device-core set-location <udid> <lat> <lon>");
                    ExitCode::from(64)
                }
            }
        }
        Some("clear-location") => match args.next() {
            Some(udid) => clear_location(&udid).await,
            None => {
                eprintln!("usage: geoteleport-device-core clear-location <udid>");
                ExitCode::from(64)
            }
        },
        Some("ios17-location-daemon") => match args.next() {
            Some(udid) => ios17_location_daemon(&udid).await,
            None => {
                eprintln!("usage: geoteleport-device-core ios17-location-daemon <udid>");
                ExitCode::from(64)
            }
        },
        Some("--version") => {
            println!("geoteleport-device-core 0.1.0");
            ExitCode::SUCCESS
        }
        _ => {
            eprintln!(
                "usage: geoteleport-device-core <enumerate-ios-devices|device-info <udid>|set-location <udid> <lat> <lon>|clear-location <udid>|ios17-location-daemon <udid>|--version>"
            );
            ExitCode::from(64)
        }
    }
}

async fn enumerate_ios_devices() -> ExitCode {
    let mut connection = match UsbmuxdConnection::default().await {
        Ok(connection) => connection,
        Err(error) => {
            eprintln!("failed to connect to usbmuxd: {error}");
            return ExitCode::from(1);
        }
    };

    let devices = match connection.get_devices().await {
        Ok(devices) => devices,
        Err(error) => {
            eprintln!("failed to enumerate iOS devices through usbmuxd: {error}");
            return ExitCode::from(1);
        }
    };

    let usb_devices = devices
        .into_iter()
        .filter(|device| matches!(device.connection_type, Connection::Usb))
        .map(|device| {
            format!(
                "{{\"simulator\":false,\"name\":\"{}\",\"identifier\":\"{}\",\"platform\":\"com.apple.platform.iphoneos\",\"interface\":\"usb\",\"operatingSystemVersion\":null}}",
                device.udid, device.udid
            )
        })
        .collect::<Vec<_>>();

    print!("[{}]", usb_devices.join(","));
    if !usb_devices.is_empty() {
        println!();
    }
    ExitCode::SUCCESS
}

async fn device_info(udid: &str) -> ExitCode {
    let device = match find_usb_device(udid).await {
        Ok(d) => d,
        Err(code) => return code,
    };

    let connection = match UsbmuxdConnection::default().await {
        Ok(c) => c,
        Err(e) => {
            eprintln!("failed to connect to usbmuxd: {e}");
            return ExitCode::from(1);
        }
    };

    let idevice = match connection
        .connect_to_device(device.device_id, LockdownClient::LOCKDOWND_PORT, "geoteleport")
        .await
    {
        Ok(i) => i,
        Err(e) => {
            eprintln!("failed to connect to lockdown service on device {udid}: {e}");
            return ExitCode::from(1);
        }
    };

    let mut lockdown = LockdownClient::new(idevice);

    let device_name = lockdown_string(&mut lockdown, "DeviceName").await;
    let product_version = lockdown_string(&mut lockdown, "ProductVersion").await;
    let unique_device_id = lockdown_string(&mut lockdown, "UniqueDeviceID").await;
    let device_class = lockdown_string(&mut lockdown, "DeviceClass").await;
    let product_type = lockdown_string(&mut lockdown, "ProductType").await;

    println!(
        "{{\"udid\":{},\"deviceName\":{},\"productVersion\":{},\"uniqueDeviceID\":{},\"deviceClass\":{},\"productType\":{}}}",
        json_str(udid),
        json_opt(device_name.as_deref()),
        json_opt(product_version.as_deref()),
        json_opt(unique_device_id.as_deref()),
        json_opt(device_class.as_deref()),
        json_opt(product_type.as_deref()),
    );
    ExitCode::SUCCESS
}

async fn set_location(udid: &str, lat: &str, lon: &str) -> ExitCode {
    if lat.parse::<f64>().is_err() || lon.parse::<f64>().is_err() {
        eprintln!("set-location: invalid coordinates: lat={lat} lon={lon}");
        return ExitCode::from(64);
    }

    let device = match find_usb_device(udid).await {
        Ok(d) => d,
        Err(code) => return code,
    };

    if let Some(major) = get_ios_major(device.device_id).await {
        if major >= 17 {
            eprintln!("iOS {major} detected: set-location requires tunnel support not yet implemented (TEMPORARY_LIMITATION)");
            return ExitCode::from(3);
        }
    }

    let provider = device.to_provider(UsbmuxdAddr::default(), "geoteleport");
    let mut service = match LocationSimulationService::connect(&provider).await {
        Ok(s) => s,
        Err(e) => {
            eprintln!("failed to start location simulation service on {udid}: {e}");
            return ExitCode::from(1);
        }
    };

    if let Err(e) = service.set(lat, lon).await {
        eprintln!("failed to set location on {udid}: {e}");
        return ExitCode::from(1);
    }

    ExitCode::SUCCESS
}

async fn clear_location(udid: &str) -> ExitCode {
    let device = match find_usb_device(udid).await {
        Ok(d) => d,
        Err(code) => return code,
    };

    if let Some(major) = get_ios_major(device.device_id).await {
        if major >= 17 {
            eprintln!("iOS {major} detected: clear-location requires tunnel support not yet implemented (TEMPORARY_LIMITATION)");
            return ExitCode::from(3);
        }
    }

    let provider = device.to_provider(UsbmuxdAddr::default(), "geoteleport");
    let mut service = match LocationSimulationService::connect(&provider).await {
        Ok(s) => s,
        Err(e) => {
            eprintln!("failed to start location simulation service on {udid}: {e}");
            return ExitCode::from(1);
        }
    };

    if let Err(e) = service.clear().await {
        eprintln!("failed to clear location on {udid}: {e}");
        return ExitCode::from(1);
    }

    ExitCode::SUCCESS
}

/// iOS 17+ location daemon: establishes CDTunnel + jktcp + RSD + DVT,
/// then reads set/clear commands from stdin and keeps the DVT connection
/// alive while location is simulated.
///
/// Protocol (newline-terminated):
///   stdin:  "set <lat> <lon>" | "clear"
///   stdout: "READY" (once, when DVT channel is open) | "OK" | "ERROR: <msg>"
///
/// The daemon exits when stdin reaches EOF or an unrecoverable error occurs.
async fn ios17_location_daemon(udid: &str) -> ExitCode {
    let device = match find_usb_device(udid).await {
        Ok(d) => d,
        Err(code) => return code,
    };

    let provider = device.to_provider(UsbmuxdAddr::default(), "geoteleport");

    // Connect to CoreDeviceProxy (performs CDTunnel handshake over USB).
    let proxy = match CoreDeviceProxy::connect(&provider).await {
        Ok(p) => p,
        Err(e) => {
            eprintln!("ios17-location-daemon: CoreDeviceProxy connection failed: {e}");
            return ExitCode::from(1);
        }
    };

    let rsd_port = proxy.tunnel_info().server_rsd_port;

    // Create an in-process userspace TCP stack over the CDTunnel.
    let adapter = match proxy.create_software_tunnel() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("ios17-location-daemon: software tunnel creation failed: {e}");
            return ExitCode::from(1);
        }
    };
    let mut adapter_handle = adapter.to_async_handle();

    // Connect to the device's RSD port through the TCP stack and perform handshake.
    let rsd_stream = match adapter_handle.connect(rsd_port).await {
        Ok(s) => s,
        Err(e) => {
            eprintln!("ios17-location-daemon: RSD port {rsd_port} connection failed: {e}");
            return ExitCode::from(1);
        }
    };

    let mut rsd = match RsdHandshake::new(rsd_stream).await {
        Ok(r) => r,
        Err(e) => {
            eprintln!("ios17-location-daemon: RSD handshake failed: {e}");
            return ExitCode::from(1);
        }
    };

    // Connect to the DTX instruments hub (com.apple.instruments.dtservicehub).
    let mut remote_server: RemoteServerClient<Box<dyn ReadWrite>> =
        match rsd.connect(&mut adapter_handle).await {
            Ok(s) => s,
            Err(e) => {
                eprintln!("ios17-location-daemon: DTX service connection failed: {e}");
                return ExitCode::from(1);
            }
        };

    // Open the location simulation channel.
    let mut loc_client = match LocationSimulationClient::new(&mut remote_server).await {
        Ok(c) => c,
        Err(e) => {
            eprintln!("ios17-location-daemon: location simulation channel failed: {e}");
            return ExitCode::from(1);
        }
    };

    // Signal readiness to the Swift side.
    println!("READY");

    // Process commands from stdin until EOF.
    let stdin = BufReader::new(tokio::io::stdin());
    let mut lines = stdin.lines();
    loop {
        let line = match lines.next_line().await {
            Ok(Some(l)) => l,
            Ok(None) => break, // EOF: caller closed stdin
            Err(e) => {
                eprintln!("ios17-location-daemon: stdin read error: {e}");
                break;
            }
        };

        let parts: Vec<&str> = line.splitn(3, ' ').collect();
        match parts.as_slice() {
            ["set", lat_str, lon_str] => {
                match (lat_str.parse::<f64>(), lon_str.parse::<f64>()) {
                    (Ok(lat), Ok(lon)) => match loc_client.set(lat, lon).await {
                        Ok(()) => println!("OK"),
                        Err(e) => println!("ERROR: {e}"),
                    },
                    _ => println!("ERROR: invalid coordinates"),
                }
            }
            ["clear"] => match loc_client.clear().await {
                Ok(()) => println!("OK"),
                Err(e) => println!("ERROR: {e}"),
            },
            _ => println!("ERROR: unknown command"),
        }
    }

    ExitCode::SUCCESS
}

async fn find_usb_device(udid: &str) -> Result<UsbmuxdDevice, ExitCode> {
    let mut connection = match UsbmuxdConnection::default().await {
        Ok(c) => c,
        Err(e) => {
            eprintln!("failed to connect to usbmuxd: {e}");
            return Err(ExitCode::from(1));
        }
    };

    let devices = match connection.get_devices().await {
        Ok(d) => d,
        Err(e) => {
            eprintln!("failed to enumerate iOS devices through usbmuxd: {e}");
            return Err(ExitCode::from(1));
        }
    };

    devices
        .into_iter()
        .find(|d| d.udid == udid && matches!(d.connection_type, Connection::Usb))
        .ok_or_else(|| {
            eprintln!("device with UDID {udid} not found over USB");
            ExitCode::from(2)
        })
}

async fn get_ios_major(device_id: u32) -> Option<u32> {
    let connection = UsbmuxdConnection::default().await.ok()?;
    let idevice = connection
        .connect_to_device(device_id, LockdownClient::LOCKDOWND_PORT, "geoteleport")
        .await
        .ok()?;
    let mut lockdown = LockdownClient::new(idevice);
    let version = lockdown_string(&mut lockdown, "ProductVersion").await?;
    version.split('.').next()?.parse::<u32>().ok()
}

async fn lockdown_string(lockdown: &mut LockdownClient, key: &str) -> Option<String> {
    lockdown
        .get_value(Some(key), None)
        .await
        .ok()
        .and_then(|v| v.as_string().map(|s| s.to_owned()))
}

fn json_str(s: &str) -> String {
    format!(
        "\"{}\"",
        s.replace('\\', "\\\\").replace('"', "\\\"")
    )
}

fn json_opt(s: Option<&str>) -> String {
    match s {
        Some(s) => json_str(s),
        None => "null".to_owned(),
    }
}
