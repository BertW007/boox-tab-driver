using System.Drawing;
using System.Drawing.Imaging;
using System.Net;
using System.Net.Sockets;

namespace BooxTabletDriver;

/// <summary>
/// Captures the primary screen and streams JPEG frames over TCP
/// to the Boox device for display mirroring.
/// </summary>
sealed class ScreenStreamer : IDisposable
{
    private int _port;
    private TcpListener? _listener;
    private CancellationTokenSource? _cts;
    private Task? _streamTask;
    private bool _running;
    private int _quality = 75;
    private int _targetFps = 15;

    public bool IsRunning => _running;

    public event Action? OnStarted;
    public event Action? OnStopped;
    public event Action<string>? OnLog;

    public int TargetFps
    {
        get => _targetFps;
        set => _targetFps = Math.Clamp(value, 1, 30);
    }

    public int JpegQuality
    {
        get => _quality;
        set => _quality = Math.Clamp(value, 10, 100);
    }

    public ScreenStreamer(int port)
    {
        _port = port;
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

        _streamTask = StreamLoop(_cts.Token);
        Log($"Screen streamer listening on port {_port}");
        OnStarted?.Invoke();
    }

    public void Stop()
    {
        if (!_running) return;

        _cts?.Cancel();
        _listener?.Stop();
        _running = false;
        Log("Screen streamer stopped");
        OnStopped?.Invoke();
    }

    private async Task StreamLoop(CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                Log("Waiting for video client...");
                using var client = await _listener!.AcceptTcpClientAsync(ct);
                using var stream = client.GetStream();
                Log($"Video client connected from {client.Client.RemoteEndPoint}");

                await SendFrames(stream, ct);
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        catch (Exception ex)
        {
            Log($"Streamer error: {ex.Message}");
        }
    }

    private async Task SendFrames(NetworkStream stream, CancellationToken ct)
    {
        var bounds = Screen.PrimaryScreen!.Bounds;
        var frameInterval = TimeSpan.FromMilliseconds(1000.0 / _targetFps);
        var jpegEncoder = ImageCodecInfo.GetImageEncoders()
            .First(c => c.FormatID == ImageFormat.Jpeg.Guid);
        var encoderParams = new EncoderParameters(1)
        {
            Param = [new EncoderParameter(Encoder.Quality, (long)_quality)]
        };

        while (!ct.IsCancellationRequested)
        {
            var start = DateTime.UtcNow;

            try
            {
                // Capture screen
                using var bitmap = new Bitmap(bounds.Width, bounds.Height);
                using (var g = Graphics.FromImage(bitmap))
                {
                    g.CopyFromScreen(bounds.X, bounds.Y, 0, 0, bounds.Size);
                }

                // Resize to fit Boox Tab X C (2200×1650 max)
                using var resized = ScaleToFit(bitmap, 2200, 1650);

                // Encode as JPEG
                using var ms = new MemoryStream();
                resized.Save(ms, jpegEncoder, encoderParams);
                var jpegData = ms.ToArray();

                // Send: 4-byte length prefix (little-endian) + JPEG data
                var header = BitConverter.GetBytes(jpegData.Length);
                await stream.WriteAsync(header, ct);
                await stream.WriteAsync(jpegData, ct);
                await stream.FlushAsync(ct);
            }
            catch (Exception ex)
            {
                Log($"Frame error: {ex.Message}");
                break;
            }

            // Maintain target framerate
            var elapsed = DateTime.UtcNow - start;
            var delay = frameInterval - elapsed;
            if (delay > TimeSpan.Zero)
                await Task.Delay(delay, ct);
        }
    }

    private static Bitmap ScaleToFit(Image image, int maxW, int maxH)
    {
        var ratioW = (double)maxW / image.Width;
        var ratioH = (double)maxH / image.Height;
        var ratio = Math.Min(ratioW, ratioH);

        if (ratio >= 1.0) return new Bitmap(image); // no resize needed

        var newW = (int)(image.Width * ratio);
        var newH = (int)(image.Height * ratio);

        var result = new Bitmap(newW, newH);
        using (var g = Graphics.FromImage(result))
        {
            g.InterpolationMode =
                System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            g.DrawImage(image, 0, 0, newW, newH);
        }
        return result;
    }

    private void Log(string msg) => OnLog?.Invoke(msg);

    public void Dispose()
    {
        Stop();
        _cts?.Dispose();
    }
}
