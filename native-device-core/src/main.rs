mod core;

use core::{
    clear_location_core, device_info_core, enumerate_ios_devices_core, find_usb_device,
    set_location_core,
};
use idevice::services::core_device_proxy::CoreDeviceProxy;
use idevice::services::dvt::location_simulation::LocationSimulationClient;
use idevice::services::dvt::remote_server::RemoteServerClient;
use idevice::services::rsd::RsdHandshake;
use idevice::usbmuxd::UsbmuxdAddr;
use idevice::IdeviceService;
use idevice::ReadWrite;
use std::env;
use std::process::ExitCode;
use tokio::io::{AsyncBufReadExt, BufReader};

#[tokio::main]
async fn main() -> ExitCode {
    let mut args = env::args().skip(1);
    match args.next().as_deref() {
        Some("enumerate-ios-devices") => cmd_enumerate().await,
        Some("device-info") => cmd_device_info(args.next().as_deref()).await,
        Some("set-location") => {
            let (udid, lat, lon) = (args.next(), args.next(), args.next());
            cmd_set_location(udid.as_deref(), lat.as_deref(), lon.as_deref()).await
        }
        Some("clear-location") => cmd_clear_location(args.next().as_deref()).await,
        Some("ios17-location-daemon") => cmd_ios17_daemon(args.next().as_deref()).await,
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

async fn cmd_enumerate() -> ExitCode {
    match enumerate_ios_devices_core().await {
        Ok(output) => {
            println!("{output}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            let resp = core::StatusResponse {
                status: core::CommandStatus::Error,
                error: Some(e),
            };
            println!("{}", serde_json::to_string(&resp).unwrap());
            ExitCode::from(1)
        }
    }
}

async fn cmd_device_info(udid: Option<&str>) -> ExitCode {
    let Some(udid) = udid else {
        eprintln!("usage: geoteleport-device-core device-info <udid>");
        return ExitCode::from(64);
    };
    match device_info_core(udid).await {
        Ok(output) => {
            println!("{output}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            let resp = core::StatusResponse {
                status: core::CommandStatus::Error,
                error: Some(e),
            };
            println!("{}", serde_json::to_string(&resp).unwrap());
            ExitCode::from(1)
        }
    }
}

async fn cmd_set_location(udid: Option<&str>, lat: Option<&str>, lon: Option<&str>) -> ExitCode {
    let (Some(udid), Some(lat), Some(lon)) = (udid, lat, lon) else {
        eprintln!("usage: geoteleport-device-core set-location <udid> <lat> <lon>");
        return ExitCode::from(64);
    };
    let (Ok(lat_val), Ok(lon_val)) = (lat.parse::<f64>(), lon.parse::<f64>()) else {
        let resp = core::StatusResponse {
            status: core::CommandStatus::Error,
            error: Some(format!("invalid coordinates: lat={lat} lon={lon}")),
        };
        println!("{}", serde_json::to_string(&resp).unwrap());
        return ExitCode::from(64);
    };
    match set_location_core(udid, lat_val, lon_val).await {
        Ok(output) => {
            println!("{output}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            let resp = core::StatusResponse {
                status: core::CommandStatus::Error,
                error: Some(e),
            };
            println!("{}", serde_json::to_string(&resp).unwrap());
            ExitCode::from(1)
        }
    }
}

async fn cmd_clear_location(udid: Option<&str>) -> ExitCode {
    let Some(udid) = udid else {
        eprintln!("usage: geoteleport-device-core clear-location <udid>");
        return ExitCode::from(64);
    };
    match clear_location_core(udid).await {
        Ok(output) => {
            println!("{output}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            let resp = core::StatusResponse {
                status: core::CommandStatus::Error,
                error: Some(e),
            };
            println!("{}", serde_json::to_string(&resp).unwrap());
            ExitCode::from(1)
        }
    }
}

async fn cmd_ios17_daemon(udid: Option<&str>) -> ExitCode {
    let Some(udid) = udid else {
        eprintln!("usage: geoteleport-device-core ios17-location-daemon <udid>");
        return ExitCode::from(64);
    };
    ios17_location_daemon(udid).await
}

async fn ios17_location_daemon(udid: &str) -> ExitCode {
    let device = match find_usb_device(udid).await {
        Ok(d) => d,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::from(1);
        }
    };

    let provider = device.to_provider(UsbmuxdAddr::default(), "geoteleport");
    let proxy = match CoreDeviceProxy::connect(&provider).await {
        Ok(p) => p,
        Err(e) => {
            eprintln!("ios17-location-daemon: CoreDeviceProxy connection failed: {e}");
            return ExitCode::from(1);
        }
    };
    let rsd_port = proxy.tunnel_info().server_rsd_port;

    let adapter = match proxy.create_software_tunnel() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("ios17-location-daemon: software tunnel creation failed: {e}");
            return ExitCode::from(1);
        }
    };
    let mut adapter_handle = adapter.to_async_handle();

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

    let mut remote_server: RemoteServerClient<Box<dyn ReadWrite>> =
        match rsd.connect(&mut adapter_handle).await {
            Ok(s) => s,
            Err(e) => {
                eprintln!("ios17-location-daemon: DTX service connection failed: {e}");
                return ExitCode::from(1);
            }
        };

    let mut loc_client = match LocationSimulationClient::new(&mut remote_server).await {
        Ok(c) => c,
        Err(e) => {
            eprintln!("ios17-location-daemon: location simulation channel failed: {e}");
            return ExitCode::from(1);
        }
    };

    println!("READY");

    let stdin = BufReader::new(tokio::io::stdin());
    let mut lines = stdin.lines();
    loop {
        let line = match lines.next_line().await {
            Ok(Some(l)) => l,
            Ok(None) => break,
            Err(e) => {
                eprintln!("ios17-location-daemon: stdin read error: {e}");
                break;
            }
        };

        let parts: Vec<&str> = line.splitn(3, ' ').collect();
        match parts.as_slice() {
            ["set", lat_str, lon_str] => match (lat_str.parse::<f64>(), lon_str.parse::<f64>()) {
                (Ok(lat), Ok(lon)) => match loc_client.set(lat, lon).await {
                    Ok(()) => println!(r#"{{"status":"ok"}}"#),
                    Err(e) => println!(
                        r#"{{"status":"error","error":{}}}"#,
                        serde_json::to_string(&e.to_string()).unwrap()
                    ),
                },
                _ => println!(r#"{{"status":"error","error":"invalid coordinates"}}"#),
            },
            ["clear"] => match loc_client.clear().await {
                Ok(()) => println!(r#"{{"status":"ok"}}"#),
                Err(e) => println!(
                    r#"{{"status":"error","error":{}}}"#,
                    serde_json::to_string(&e.to_string()).unwrap()
                ),
            },
            _ => println!(r#"{{"status":"error","error":"unknown command"}}"#),
        }
    }

    ExitCode::SUCCESS
}
