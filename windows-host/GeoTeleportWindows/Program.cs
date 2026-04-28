using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace GeoTeleportWindows;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new MainForm());
    }
}

internal sealed class MainForm : Form
{
    private readonly ComboBox deviceCombo = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly Button refreshButton = new() { Text = "Refresh" };
    private readonly Button infoButton = new() { Text = "Device Info" };
    private readonly Button setButton = new() { Text = "Set" };
    private readonly Button clearButton = new() { Text = "Clear" };
    private readonly Button exportButton = new() { Text = "Export Diagnostics" };
    private readonly TextBox latBox = new() { Text = "37.334900" };
    private readonly TextBox lonBox = new() { Text = "-122.009020" };
    private readonly TextBox logBox = new()
    {
        Multiline = true,
        ReadOnly = true,
        ScrollBars = ScrollBars.Vertical,
        Font = new Font(FontFamily.GenericMonospace, 9.0f)
    };
    private readonly Label statusLabel = new()
    {
        AutoSize = false,
        Text = "Ready",
        TextAlign = ContentAlignment.MiddleLeft
    };

    public MainForm()
    {
        Text = "GeoTeleport Windows";
        MinimumSize = new Size(860, 560);
        StartPosition = FormStartPosition.CenterScreen;

        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(12),
            ColumnCount = 1,
            RowCount = 4
        };
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 30));

        var deviceRow = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 5 };
        deviceRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        deviceRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 110));
        deviceRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 110));
        deviceRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 140));
        deviceRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 150));
        deviceRow.Controls.Add(deviceCombo, 0, 0);
        deviceRow.Controls.Add(refreshButton, 1, 0);
        deviceRow.Controls.Add(infoButton, 2, 0);
        deviceRow.Controls.Add(clearButton, 3, 0);
        deviceRow.Controls.Add(exportButton, 4, 0);

        var locationRow = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 5 };
        locationRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 90));
        locationRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        locationRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 90));
        locationRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        locationRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 110));
        locationRow.Controls.Add(new Label { Text = "Latitude", TextAlign = ContentAlignment.MiddleLeft, Dock = DockStyle.Fill }, 0, 0);
        locationRow.Controls.Add(latBox, 1, 0);
        locationRow.Controls.Add(new Label { Text = "Longitude", TextAlign = ContentAlignment.MiddleLeft, Dock = DockStyle.Fill }, 2, 0);
        locationRow.Controls.Add(lonBox, 3, 0);
        locationRow.Controls.Add(setButton, 4, 0);

        root.Controls.Add(deviceRow, 0, 0);
        root.Controls.Add(locationRow, 0, 1);
        root.Controls.Add(logBox, 0, 2);
        root.Controls.Add(statusLabel, 0, 3);
        Controls.Add(root);

        refreshButton.Click += async (_, _) => await RefreshDevicesAsync();
        infoButton.Click += async (_, _) => await LoadDeviceInfoAsync();
        setButton.Click += async (_, _) => await SetLocationAsync();
        clearButton.Click += async (_, _) => await ClearLocationAsync();
        exportButton.Click += (_, _) => ExportDiagnostics();

        Shown += async (_, _) => await RefreshDevicesAsync();
    }

    private DeviceEntry? SelectedDevice => deviceCombo.SelectedItem as DeviceEntry;

    private async Task RefreshDevicesAsync()
    {
        await RunCoreCallAsync("enumerate", () =>
        {
            var json = NativeCore.EnumerateDevices();
            var devices = JsonSerializer.Deserialize<List<DeviceEntry>>(json, JsonOptions.Default) ?? [];
            OnUi(() =>
            {
                deviceCombo.Items.Clear();
                foreach (var device in devices)
                {
                    deviceCombo.Items.Add(device);
                }
                if (deviceCombo.Items.Count > 0)
                {
                    deviceCombo.SelectedIndex = 0;
                }
                Log(devices.Count == 0 ? "No USB iPhone detected." : $"Detected {devices.Count} USB device(s).");
            });
        });
    }

    private async Task LoadDeviceInfoAsync()
    {
        if (!RequireDevice(out var device)) return;
        await RunCoreCallAsync("device-info", () =>
        {
            var json = NativeCore.DeviceInfo(device.Identifier);
            var info = JsonSerializer.Deserialize<DeviceInfo>(json, JsonOptions.Default);
            OnUi(() =>
            {
                Log("Device info:");
                Log($"  Name: {info?.DeviceName ?? "(unknown)"}");
                Log($"  iOS: {info?.ProductVersion ?? "(unknown)"}");
                Log($"  Type: {info?.ProductType ?? "(unknown)"}");
                Log($"  UDID: {info?.Udid ?? device.Identifier}");
            });
        });
    }

    private async Task SetLocationAsync()
    {
        if (!RequireDevice(out var device)) return;
        if (!double.TryParse(latBox.Text, out _) || !double.TryParse(lonBox.Text, out _))
        {
            Log("Invalid coordinates.");
            return;
        }
        await RunCoreCallAsync("set-location", () =>
        {
            var json = NativeCore.SetLocation(device.Identifier, latBox.Text.Trim(), lonBox.Text.Trim());
            var status = JsonSerializer.Deserialize<StatusResponse>(json, JsonOptions.Default);
            if (RequiresIos17Daemon(status))
            {
                json = Ios17DaemonClient.Send(device.Identifier, $"set {latBox.Text.Trim()} {lonBox.Text.Trim()}");
                status = JsonSerializer.Deserialize<StatusResponse>(json, JsonOptions.Default);
            }
            OnUi(() => Log(status?.Status == "ok" ? "Location set." : $"Set failed: {status?.Error ?? json}"));
        });
    }

    private async Task ClearLocationAsync()
    {
        if (!RequireDevice(out var device)) return;
        await RunCoreCallAsync("clear-location", () =>
        {
            var json = NativeCore.ClearLocation(device.Identifier);
            var status = JsonSerializer.Deserialize<StatusResponse>(json, JsonOptions.Default);
            if (RequiresIos17Daemon(status))
            {
                json = Ios17DaemonClient.Send(device.Identifier, "clear");
                status = JsonSerializer.Deserialize<StatusResponse>(json, JsonOptions.Default);
            }
            OnUi(() => Log(status?.Status == "ok" ? "Location cleared." : $"Clear failed: {status?.Error ?? json}"));
        });
    }

    private async Task RunCoreCallAsync(string name, Action action)
    {
        SetBusy(true, $"{name} running...");
        try
        {
            await Task.Run(action);
            SetBusy(false, $"{name} complete");
        }
        catch (DllNotFoundException ex)
        {
            SetBusy(false, "Native core DLL missing");
            Log($"Cannot load geoteleport_device_core.dll. Place it next to GeoTeleportWindows.exe. {ex.Message}");
        }
        catch (Exception ex)
        {
            SetBusy(false, $"{name} failed");
            Log($"{name} failed: {ex.Message}");
        }
    }

    private bool RequireDevice(out DeviceEntry device)
    {
        if (SelectedDevice is { } selected)
        {
            device = selected;
            return true;
        }
        Log("Select a USB device first.");
        device = default!;
        return false;
    }

    private static bool RequiresIos17Daemon(StatusResponse? status)
    {
        return status?.Error?.Contains("ios17-location-daemon", StringComparison.OrdinalIgnoreCase) == true;
    }

    private void ExportDiagnostics()
    {
        using var dialog = new SaveFileDialog
        {
            Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*",
            FileName = $"GeoTeleport_Windows_Diagnostics_{DateTime.Now:yyyyMMdd_HHmmss}.txt"
        };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;

        var builder = new StringBuilder();
        builder.AppendLine("GeoTeleport Windows Diagnostics");
        builder.AppendLine($"Timestamp: {DateTimeOffset.Now}");
        builder.AppendLine($"OS: {Environment.OSVersion}");
        builder.AppendLine($".NET: {Environment.Version}");
        builder.AppendLine($"Selected device: {SelectedDevice?.Identifier ?? "(none)"}");
        builder.AppendLine();
        builder.AppendLine(logBox.Text);
        File.WriteAllText(dialog.FileName, builder.ToString());
        Log($"Diagnostics exported: {dialog.FileName}");
    }

    private void SetBusy(bool busy, string status)
    {
        OnUi(() =>
        {
            refreshButton.Enabled = !busy;
            infoButton.Enabled = !busy;
            setButton.Enabled = !busy;
            clearButton.Enabled = !busy;
            exportButton.Enabled = !busy;
            statusLabel.Text = status;
        });
    }

    private void OnUi(Action action)
    {
        if (IsDisposed) return;
        if (InvokeRequired)
        {
            BeginInvoke((MethodInvoker)(() => action()));
            return;
        }
        action();
    }

    private void Log(string message)
    {
        var line = $"[{DateTime.Now:HH:mm:ss}] {message}{Environment.NewLine}";
        if (InvokeRequired)
        {
            BeginInvoke((MethodInvoker)(() => logBox.AppendText(line)));
        }
        else
        {
            logBox.AppendText(line);
        }
    }
}

internal static class Ios17DaemonClient
{
    public static string Send(string udid, string command)
    {
        var exePath = Path.Combine(AppContext.BaseDirectory, "geoteleport-device-core.exe");
        if (!File.Exists(exePath))
        {
            return Error($"iOS 17+ location requires geoteleport-device-core.exe beside the Windows host: {exePath}");
        }

        using var process = new System.Diagnostics.Process();
        process.StartInfo = new System.Diagnostics.ProcessStartInfo
        {
            FileName = exePath,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        process.StartInfo.ArgumentList.Add("ios17-location-daemon");
        process.StartInfo.ArgumentList.Add(udid);

        if (!process.Start())
        {
            return Error("failed to start ios17-location-daemon");
        }

        try
        {
            var ready = ReadLineWithTimeout(process.StandardOutput, TimeSpan.FromSeconds(20));
            if (!string.Equals(ready, "READY", StringComparison.Ordinal))
            {
                return Error($"ios17-location-daemon did not become ready: {ready ?? "(no output)"} {ReadAvailableError(process)}");
            }

            process.StandardInput.WriteLine(command);
            process.StandardInput.Flush();

            var response = ReadLineWithTimeout(process.StandardOutput, TimeSpan.FromSeconds(30));
            return string.IsNullOrWhiteSpace(response)
                ? Error($"ios17-location-daemon returned no response. {ReadAvailableError(process)}")
                : response;
        }
        finally
        {
            try
            {
                process.StandardInput.Close();
                if (!process.WaitForExit(1500))
                {
                    process.Kill(entireProcessTree: true);
                }
            }
            catch
            {
            }
        }
    }

    private static string? ReadLineWithTimeout(StreamReader reader, TimeSpan timeout)
    {
        var task = reader.ReadLineAsync();
        return task.Wait(timeout) ? task.Result : null;
    }

    private static string ReadAvailableError(System.Diagnostics.Process process)
    {
        try
        {
            return process.HasExited ? process.StandardError.ReadToEnd() : "";
        }
        catch
        {
            return "";
        }
    }

    private static string Error(string message)
    {
        return JsonSerializer.Serialize(new StatusResponse("error", message), JsonOptions.Default);
    }
}

internal static class NativeCore
{
    [DllImport("geoteleport_device_core", CallingConvention = CallingConvention.Cdecl)]
    private static extern nint gte_enumerate_ios_devices();

    [DllImport("geoteleport_device_core", CallingConvention = CallingConvention.Cdecl)]
    private static extern nint gte_device_info([MarshalAs(UnmanagedType.LPUTF8Str)] string udid);

    [DllImport("geoteleport_device_core", CallingConvention = CallingConvention.Cdecl)]
    private static extern nint gte_set_location(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string udid,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string lat,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string lon);

    [DllImport("geoteleport_device_core", CallingConvention = CallingConvention.Cdecl)]
    private static extern nint gte_clear_location([MarshalAs(UnmanagedType.LPUTF8Str)] string udid);

    [DllImport("geoteleport_device_core", CallingConvention = CallingConvention.Cdecl)]
    private static extern void gte_free_string(nint ptr);

    public static string EnumerateDevices() => TakeString(gte_enumerate_ios_devices());
    public static string DeviceInfo(string udid) => TakeString(gte_device_info(udid));
    public static string SetLocation(string udid, string lat, string lon) => TakeString(gte_set_location(udid, lat, lon));
    public static string ClearLocation(string udid) => TakeString(gte_clear_location(udid));

    private static string TakeString(nint ptr)
    {
        if (ptr == 0) throw new InvalidOperationException("native core returned null");
        try
        {
            return Marshal.PtrToStringUTF8(ptr) ?? "";
        }
        finally
        {
            gte_free_string(ptr);
        }
    }
}

internal sealed record DeviceEntry(
    [property: JsonPropertyName("simulator")] bool Simulator,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("identifier")] string Identifier,
    [property: JsonPropertyName("platform")] string Platform,
    [property: JsonPropertyName("interface")] string Interface,
    [property: JsonPropertyName("operatingSystemVersion")] string? OperatingSystemVersion)
{
    public override string ToString()
    {
        var version = string.IsNullOrWhiteSpace(OperatingSystemVersion) ? "" : $" iOS {OperatingSystemVersion}";
        return $"{Name}{version} - {Identifier}";
    }
}

internal sealed record DeviceInfo(
    [property: JsonPropertyName("udid")] string Udid,
    [property: JsonPropertyName("device_name")] string? DeviceName,
    [property: JsonPropertyName("product_version")] string? ProductVersion,
    [property: JsonPropertyName("unique_device_id")] string? UniqueDeviceId,
    [property: JsonPropertyName("device_class")] string? DeviceClass,
    [property: JsonPropertyName("product_type")] string? ProductType);

internal sealed record StatusResponse(
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("error")] string? Error);

internal static class JsonOptions
{
    public static readonly JsonSerializerOptions Default = new()
    {
        PropertyNameCaseInsensitive = true
    };
}
