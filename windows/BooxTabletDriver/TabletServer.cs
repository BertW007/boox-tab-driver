using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace BooxTabletDriver;

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
    public event Action? OnClientConnected;
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

                Log($"Device connected from {client.Client.RemoteEndPoint}");
                OnClientConnected?.Invoke();

                // Tell the device the PC screen resolution for letterbox compensation
                try
                {
                    var b = Screen.PrimaryScreen!.Bounds;
                    var msg = $"{{\"type\":\"screen_info\",\"width\":{b.Width},\"height\":{b.Height}}}\n";
                    await _stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes(msg));
                }
                catch { }

                await HandleClient(ct);

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

    private void ProcessMessage(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            var type = root.GetProperty("type").GetString();

            if (type == "key")
            {
                var action = root.GetProperty("action").GetString() ?? "down";
                var ch    = root.TryGetProperty("char",    out var cProp) ? cProp.GetString() ?? "" : "";
                var label = root.TryGetProperty("label",   out var lProp) ? lProp.GetString() ?? "" : "";
                _injector.InjectKey(action, ch, label);
                return;
            }

            if (type == "scroll")
            {
                var sx = root.TryGetProperty("x",  out var sxP) ? sxP.GetSingle() : 0f;
                var sy = root.TryGetProperty("y",  out var syP) ? syP.GetSingle() : 0f;
                var dx = root.TryGetProperty("dx", out var dxP) ? dxP.GetSingle() : 0f;
                var dy = root.TryGetProperty("dy", out var dyP) ? dyP.GetSingle() : 0f;
                _injector.InjectScroll(sx, sy, dx, dy);
                return;
            }

            if (type != "pen") return;

            var penAction = root.GetProperty("action").GetString() ?? "move";
            var x = root.GetProperty("x").GetSingle();
            var y = root.GetProperty("y").GetSingle();
            var pressure = root.GetProperty("pressure").GetSingle();
            var button = root.TryGetProperty("button", out var btnProp) ? btnProp.GetString() ?? "primary" : "primary";

            if (penAction == "down")
                Log($"Pen down x={x:F3} y={y:F3} p={pressure:F2} btn={button}");

            switch (penAction)
            {
                case "down":
                    _injector.PenDown(x, y, pressure, button);
                    break;
                case "move":
                    _injector.PenMove(x, y, pressure);
                    break;
                case "up":
                    _injector.PenUp();
                    break;
            }
        }
        catch (JsonException ex)
        {
            Log($"JSON parse error: {ex.Message}");
        }
        catch (Exception ex)
        {
            Log($"Process error: {ex.Message}");
        }
    }

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
