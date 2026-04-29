using System.Net;
using System.Text;
using InTheHand.Net.Bluetooth;
using InTheHand.Net.Sockets;

namespace BooxTabletDriver;

sealed class BluetoothServer : IDisposable
{
    private readonly InputInjector _injector;
    private BluetoothListener? _listener;
    private CancellationTokenSource? _cts;
    private Task? _listenTask;
    private bool _running;

    public bool IsRunning => _running;

    public event Action? OnStarted;
    public event Action? OnStopped;
    public event Action<string>? OnClientConnected;  // passes device name
    public event Action? OnClientDisconnected;
    public event Action<string>? OnLog;

    public BluetoothServer(InputInjector injector)
    {
        _injector = injector;
    }

    public void Start()
    {
        if (_running) return;
        try
        {
            _listener = new BluetoothListener(BluetoothService.SerialPort)
            {
                ServiceName = "Boox Tablet Driver"
            };
            _listener.Start();
            _running = true;
            _cts = new CancellationTokenSource();
            _listenTask = AcceptLoop(_cts.Token);
            Log("Bluetooth server started (SPP)");
            OnStarted?.Invoke();
        }
        catch (Exception ex)
        {
            Log($"Bluetooth start failed: {ex.Message}");
        }
    }

    public void Stop()
    {
        if (!_running) return;
        _cts?.Cancel();
        try { _listener?.Stop(); } catch { }
        _running = false;
        Log("Bluetooth server stopped");
        OnStopped?.Invoke();
    }

    private async Task AcceptLoop(CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                Log("Waiting for Bluetooth device...");
                BluetoothClient client = await Task.Run(
                    () => _listener!.AcceptBluetoothClient(), ct);

                var deviceName = client.RemoteMachineName;
                Log($"Bluetooth device connected: {deviceName}");
                OnClientConnected?.Invoke(deviceName);

                try
                {
                    var stream = client.GetStream();
                    var b = Screen.PrimaryScreen!.Bounds;
                    var hostname = Dns.GetHostName();
                    var msg = $"{{\"type\":\"screen_info\",\"hostname\":\"{hostname}\",\"width\":{b.Width},\"height\":{b.Height}}}\n";
                    await stream.WriteAsync(Encoding.UTF8.GetBytes(msg));

                    await HandleClient(stream, ct);
                }
                catch { }

                client.Close();
                Log($"Bluetooth device disconnected: {deviceName}");
                OnClientDisconnected?.Invoke();
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { Log($"Bluetooth error: {ex.Message}"); }
    }

    private async Task HandleClient(System.IO.Stream stream, CancellationToken ct)
    {
        var buffer = new byte[8192];
        var leftover = string.Empty;
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var bytesRead = await stream.ReadAsync(buffer, ct);
                if (bytesRead == 0) break;

                var chunk = leftover + Encoding.UTF8.GetString(buffer, 0, bytesRead);
                var lines = chunk.Split('\n');
                leftover = lines[^1];
                for (int i = 0; i < lines.Length - 1; i++)
                {
                    var line = lines[i].Trim();
                    if (!string.IsNullOrEmpty(line))
                        ProtocolHandler.Process(line, _injector, Log);
                }
            }
        }
        catch (System.IO.IOException ex) { Log($"BT IO error: {ex.Message}"); }
        catch (OperationCanceledException) { }
    }

    private void Log(string msg) => OnLog?.Invoke(msg);

    public void Dispose()
    {
        Stop();
        _cts?.Dispose();
    }
}
