using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

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
    private readonly WebView2 webView = new() { Dock = DockStyle.Fill };

    public MainForm()
    {
        Text = "GeoTeleport";
        MinimumSize = new Size(800, 650);
        Size = new Size(1100, 760);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.Black;
        Controls.Add(webView);
        
        _ = InitializeAsync();
    }

    private async Task InitializeAsync()
    {
        try
        {
            await webView.EnsureCoreWebView2Async(null);
            webView.CoreWebView2.SetVirtualHostNameToFolderMapping(
                "app.local", 
                Path.Combine(AppContext.BaseDirectory, "wwwroot"), 
                CoreWebView2HostResourceAccessKind.Allow);
            
            webView.CoreWebView2.AddHostObjectToScript("bridge", new AppBridge(this));
            webView.CoreWebView2.Navigate("http://app.local/index.html");
        }
        catch (Exception ex)
        {
            MessageBox.Show($"初始化 WebView2 失败。请确认已安装 WebView2 Runtime。\n\n{ex.Message}", "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}

[ComVisible(true)]
[ClassInterface(ClassInterfaceType.AutoDual)]
public class AppBridge
{
    private readonly MainForm _form;
    internal AppBridge(MainForm form) { _form = form; }

    public string EnumerateDevices()
    {
        try
        {
            return NativeCore.EnumerateDevices();
        }
        catch (DllNotFoundException)
        {
            throw new Exception("缺少原生核心 DLL，无法加载 geoteleport_device_core.dll。");
        }
        catch (Exception ex)
        {
            throw new Exception($"枚举设备失败：{ex.Message}");
        }
    }

    public string DeviceInfo(string udid)
    {
        try
        {
            return NativeCore.DeviceInfo(udid);
        }
        catch (Exception ex)
        {
            throw new Exception($"获取设备信息失败：{ex.Message}");
        }
    }

    public string SetLocation(string udid, string lat, string lon)
    {
        try
        {
            var json = NativeCore.SetLocation(udid, lat, lon);
            var status = JsonSerializer.Deserialize<StatusResponse>(json, JsonOptions.Default);
            if (status?.Error?.Contains("ios17-location-daemon", StringComparison.OrdinalIgnoreCase) == true)
            {
                json = Ios17DaemonClient.Send(udid, $"set {lat} {lon}");
            }
            return json;
        }
        catch (Exception ex)
        {
            throw new Exception($"设置定位失败：{ex.Message}");
        }
    }

    public string ClearLocation(string udid)
    {
        try
        {
            var json = NativeCore.ClearLocation(udid);
            var status = JsonSerializer.Deserialize<StatusResponse>(json, JsonOptions.Default);
            if (status?.Error?.Contains("ios17-location-daemon", StringComparison.OrdinalIgnoreCase) == true)
            {
                json = Ios17DaemonClient.Send(udid, "clear");
            }
            return json;
        }
        catch (Exception ex)
        {
            throw new Exception($"清除定位失败：{ex.Message}");
        }
    }

    public void ExportDiagnostics(string udid, string logs)
    {
        _form.Invoke(() =>
        {
            using var dialog = new SaveFileDialog
            {
                Filter = "文本文件 (*.txt)|*.txt|所有文件 (*.*)|*.*",
                FileName = $"GeoTeleport_Windows_诊断_{DateTime.Now:yyyyMMdd_HHmmss}.txt"
            };
            if (dialog.ShowDialog(_form) != DialogResult.OK) return;

            var builder = new StringBuilder();
            builder.AppendLine("GeoTeleport Windows版诊断");
            builder.AppendLine($"时间：{DateTimeOffset.Now}");
            builder.AppendLine($"操作系统：{Environment.OSVersion}");
            builder.AppendLine($".NET: {Environment.Version}");
            builder.AppendLine($"已选设备：{(string.IsNullOrWhiteSpace(udid) ? "无" : udid)}");
            builder.AppendLine();
            builder.AppendLine(logs);
            File.WriteAllText(dialog.FileName, builder.ToString());
        });
    }
}

internal static class Ios17DaemonClient
{
    public static string Send(string udid, string command)
    {
        var exePath = Path.Combine(AppContext.BaseDirectory, "geoteleport-device-core.exe");
        if (!File.Exists(exePath))
        {
            return Error($"iOS 17+ 定位需要 geoteleport-device-core.exe 位于 Windows 主程序旁边：{exePath}");
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
            return Error("启动 ios17-location-daemon 失败");
        }

        try
        {
            var ready = ReadLineWithTimeout(process.StandardOutput, TimeSpan.FromSeconds(20));
            if (!string.Equals(ready, "READY", StringComparison.Ordinal))
            {
                return Error($"ios17-location-daemon 未进入就绪状态：{ready ?? "无输出"} {ReadAvailableError(process)}");
            }

            process.StandardInput.WriteLine(command);
            process.StandardInput.Flush();

            var response = ReadLineWithTimeout(process.StandardOutput, TimeSpan.FromSeconds(30));
            return string.IsNullOrWhiteSpace(response)
                ? Error($"ios17-location-daemon 没有返回响应。{ReadAvailableError(process)}")
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
        if (ptr == 0) throw new InvalidOperationException("原生核心返回空结果");
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
