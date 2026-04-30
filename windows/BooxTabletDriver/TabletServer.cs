using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace BooxTabletDriver;

static class CursorTracker
{
    [StructLayout(LayoutKind.Sequential)]
    struct CURSORINFO { public int cbSize; public int flags; public IntPtr hCursor; public POINT ptScreenPos; }
    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int x; public int y; }

    [DllImport("user32.dll")] static extern bool GetCursorInfo(ref CURSORINFO pci);
    [DllImport("user32.dll")] static extern IntPtr LoadCursor(IntPtr hInst, int id);
    [DllImport("user32.dll")] static extern short GetKeyState(int nVirtKey);

    const int OCR_NORMAL   = 32512;
    const int OCR_IBEAM    = 32513;
    const int OCR_WAIT     = 32514;
    const int OCR_CROSS    = 32515;
    const int OCR_SIZENWSE = 32642;
    const int OCR_SIZENESW = 32643;
    const int OCR_SIZEWE   = 32644;
    const int OCR_SIZENS   = 32645;
    const int OCR_SIZEALL  = 32646;
    const int OCR_NO       = 32648;
    const int OCR_HAND     = 32649;

    static readonly (IntPtr handle, string name)[] _map;

    static CursorTracker()
    {
        _map =
        [
            (LoadCursor(IntPtr.Zero, OCR_NORMAL),   "arrow"),
            (LoadCursor(IntPtr.Zero, OCR_IBEAM),    "ibeam"),
            (LoadCursor(IntPtr.Zero, OCR_WAIT),     "wait"),
            (LoadCursor(IntPtr.Zero, OCR_CROSS),    "crosshair"),
            (LoadCursor(IntPtr.Zero, OCR_SIZENWSE), "size_nwse"),
            (LoadCursor(IntPtr.Zero, OCR_SIZENESW), "size_nesw"),
            (LoadCursor(IntPtr.Zero, OCR_SIZEWE),   "size_ew"),
            (LoadCursor(IntPtr.Zero, OCR_SIZENS),   "size_ns"),
            (LoadCursor(IntPtr.Zero, OCR_SIZEALL),  "size_all"),
            (LoadCursor(IntPtr.Zero, OCR_NO),       "no"),
            (LoadCursor(IntPtr.Zero, OCR_HAND),     "hand"),
        ];
    }

    public static string GetShape()
    {
        var ci = new CURSORINFO { cbSize = Marshal.SizeOf<CURSORINFO>() };
        if (!GetCursorInfo(ref ci)) return "arrow";
        foreach (var (h, name) in _map)
            if (h == ci.hCursor) return name;
        return "arrow";
    }

    public static bool CapsLock    => (GetKeyState(0x14) & 1) != 0;
    public static bool NumLock     => (GetKeyState(0x90) & 1) != 0;
    public static bool ScrollLock  => (GetKeyState(0x91) & 1) != 0;
}

enum TransportMode { WiFi, Usb, Bluetooth }

sealed class TabletServer : IDisposable
{
    private int _port;
    private readonly InputInjector _injector;
    private TcpListener? _listener;
    private CancellationTokenSource? _cts;
    private Task? _listenTask;
    private bool _running;

    public bool IsRunning => _running;
    public bool IsClientConnected => _client != null;

    // Events for UI updates
    public event Action? OnStarted;
    public event Action? OnStopped;
    public event Action<string>? OnClientConnected;  // passes "IP:port" of client
    public event Action? OnClientDisconnected;
    public event Action<string>? OnLog;

    private TcpClient? _client;
    private NetworkStream? _stream;

    public TabletServer(int port, InputInjector injector)
    {
        _port = port;
        _injector = injector;
    }

    public void UpdatePort(int port)
    {
        if (!_running) _port = port;
    }

    public void Start()
    {
        if (_running) return;

        _cts = new CancellationTokenSource();
        _listener = new TcpListener(IPAddress.Any, _port);
        _listener.Start();
        _running = true;

        _listenTask = AcceptLoop(_cts.Token);
        Log($"Server listening on port {_port}");
        OnStarted?.Invoke();
    }

    public void Stop()
    {
        if (!_running) return;

        _cts?.Cancel();
        _client?.Close();
        _listener?.Stop();
        _running = false;
        _client = null;
        _stream = null;

        Log("Server stopped");
        OnStopped?.Invoke();
    }

    private async Task AcceptLoop(CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                Log("Waiting for Boox device...");
                var client = await _listener!.AcceptTcpClientAsync(ct);

                // Drop previous client if any
                _client?.Close();
                _client = client;
                _stream = client.GetStream();

                var endpoint = client.Client.RemoteEndPoint?.ToString() ?? "unknown";
                Log($"Device connected from {endpoint}");
                OnClientConnected?.Invoke(endpoint);

                // Tell the device the PC screen resolution + hostname
                try
                {
                    var b = Screen.PrimaryScreen!.Bounds;
                    var hostname = Dns.GetHostName();
                    var msg = $"{{\"type\":\"screen_info\",\"hostname\":\"{hostname}\",\"width\":{b.Width},\"height\":{b.Height}}}\n";
                    await _stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes(msg));
                }
                catch { }

                var cursorCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                var cursorTask = PollCursorAsync(cursorCts.Token);
                await HandleClient(ct);
                cursorCts.Cancel();
                await cursorTask.ConfigureAwait(false);

                _injector.ReleaseAll();
                Log("Device disconnected");
                OnClientDisconnected?.Invoke();
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        catch (Exception ex)
        {
            Log($"Server error: {ex.Message}");
        }
    }

    private async Task HandleClient(CancellationToken ct)
    {
        var buffer = new byte[8192];
        var leftover = string.Empty;

        try
        {
            while (!ct.IsCancellationRequested && _stream != null)
            {
                var bytesRead = await _stream.ReadAsync(buffer, ct);
                if (bytesRead == 0) { Log("Client closed connection (0 bytes)"); break; }

                var chunk = leftover + Encoding.UTF8.GetString(buffer, 0, bytesRead);
                var lines = chunk.Split('\n');

                // Last element is incomplete if no trailing newline
                leftover = lines[^1];
                for (int i = 0; i < lines.Length - 1; i++)
                {
                    var line = lines[i].Trim();
                    if (string.IsNullOrEmpty(line)) continue;
                    ProcessMessage(line);
                }
            }
        }
        catch (IOException ex) { Log($"Client IO error: {ex.Message}"); }
        catch (OperationCanceledException) { }
    }

    private async Task PollCursorAsync(CancellationToken ct)
    {
        var lastCursor = "";
        var lastCaps   = false;
        var lastNum    = false;
        var lastScroll = false;
        try
        {
            while (!ct.IsCancellationRequested && _stream != null)
            {
                var shape  = CursorTracker.GetShape();
                var caps   = CursorTracker.CapsLock;
                var num    = CursorTracker.NumLock;
                var scroll = CursorTracker.ScrollLock;

                var sb = new System.Text.StringBuilder();
                if (shape != lastCursor) { lastCursor = shape; sb.Append($"{{\"type\":\"cursor\",\"shape\":\"{shape}\"}}\n"); }
                if (caps   != lastCaps   || num != lastNum || scroll != lastScroll)
                {
                    lastCaps = caps; lastNum = num; lastScroll = scroll;
                    sb.Append($"{{\"type\":\"led\",\"caps\":{(caps ? "true" : "false")},\"num\":{(num ? "true" : "false")},\"scroll\":{(scroll ? "true" : "false")}}}\n");
                }

                if (sb.Length > 0)
                {
                    try { await _stream.WriteAsync(Encoding.UTF8.GetBytes(sb.ToString()), ct); }
                    catch { break; }
                }
                await Task.Delay(80, ct);
            }
        }
        catch (OperationCanceledException) { }
    }

    private void ProcessMessage(string json) =>
        ProtocolHandler.Process(json, _injector, Log);

    private void Log(string msg)
    {
        OnLog?.Invoke(msg);
    }

    public void Dispose()
    {
        Stop();
        _cts?.Dispose();
    }
}
