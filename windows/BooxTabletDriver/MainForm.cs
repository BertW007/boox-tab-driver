using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Security.Principal;

namespace BooxTabletDriver;

sealed class MainForm : Form
{
    private readonly InputInjector _injector = new();
    private readonly TabletServer _server;
    private readonly BluetoothServer _btServer;
    private readonly ScreenStreamer _screenStreamer;

    // Controls
    private readonly NumericUpDown _portInput = new() { Minimum = 1024, Maximum = 65535, Value = 52017 };
    private readonly NumericUpDown _videoPortInput = new() { Minimum = 1024, Maximum = 65535, Value = 52018 };
    private readonly Button _startStopBtn = new() { Text = "Start", Width = 120, Height = 36 };
    private readonly Button _adbWifiBtn = new() { Text = "ADB WiFi ON", Width = 110, Height = 36 };
    private readonly Label _statusLabel = new() { AutoSize = true };
    private readonly Label _clientLabel = new() { AutoSize = true };
    private readonly Label _backendLabel = new() { AutoSize = true };
    private readonly Label _videoLabel = new() { AutoSize = true };
    private readonly Label _ipLabel = new() { AutoSize = true, Font = new Font("Consolas", 9f) };
    private readonly TextBox _logBox = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, BackColor = SystemColors.Window, Font = new Font("Consolas", 8.5f) };
    private readonly CheckBox _topMostCheck = new() { Text = "Always on top", Checked = true };
    private readonly CheckBox _mirrorCheck = new() { Text = "Screen mirroring", Checked = true };
    private readonly TrackBar _fpsSlider = new() { Minimum = 1, Maximum = 25, Value = 12, TickFrequency = 4, Width = 140 };
    private readonly ComboBox _modeSelector = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 160 };

    private static readonly string SettingsPath =
        Path.Combine(AppContext.BaseDirectory, "boox-settings.json");

    public MainForm()
    {
        Text = "Boox Tablet Driver";
        Size = new Size(560, 660);
        MinimumSize = new Size(440, 500);
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;

        _server = new TabletServer((int)_portInput.Value, _injector);
        _btServer = new BluetoothServer(_injector);
        _screenStreamer = new ScreenStreamer((int)_videoPortInput.Value);

        _injector.Initialize();
        _injector.OnError += (msg) => this.Invoke(() => AppendLog(msg));

        BuildUI();
        WireEvents();
        LoadSettings();
        UpdateStatus("Stopped", Color.Gray);
        _backendLabel.Text = $"Backend: {DescribeBackend(_injector.Backend)}";

        _ipLabel.Text = GetLocalIps();
        if (!IsAdmin())
        {
            AppendLog("WARNING: Not running as Administrator — Touch Injection and firewall setup unavailable.");
            AppendLog("Right-click BooxTabletDriver.exe → Run as administrator.");
        }

        if (Environment.GetCommandLineArgs().Contains("--autostart"))
            Shown += (_, _) => StartAll();
    }

    private void BuildUI()
    {
        var table = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(12),
            ColumnCount = 2,
            RowCount = 9,
        };
        table.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        for (int i = 0; i < 8; i++)
            table.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        table.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        // Row 0: transport mode
        table.Controls.Add(new Label { Text = "Transport:", TextAlign = ContentAlignment.MiddleLeft, AutoSize = true }, 0, 0);
        _modeSelector.Items.AddRange(["WiFi", "USB (ADB)", "Bluetooth"]);
        _modeSelector.SelectedIndex = 0;
        table.Controls.Add(_modeSelector, 1, 0);

        // Row 1: control port + start button
        table.Controls.Add(new Label { Text = "Control port:", TextAlign = ContentAlignment.MiddleLeft, AutoSize = true }, 0, 1);
        var portPanel = new FlowLayoutPanel { FlowDirection = FlowDirection.LeftToRight, AutoSize = true };
        portPanel.Controls.Add(_portInput);
        portPanel.Controls.Add(new Label { Text = "Video port:", TextAlign = ContentAlignment.MiddleLeft, AutoSize = true });
        portPanel.Controls.Add(_videoPortInput);
        portPanel.Controls.Add(_startStopBtn);
        portPanel.Controls.Add(_adbWifiBtn);
        table.Controls.Add(portPanel, 1, 1);

        // Row 2: screen mirroring options
        table.Controls.Add(new Label { Text = "Mirroring:", TextAlign = ContentAlignment.MiddleLeft, AutoSize = true }, 0, 2);
        var mirrorPanel = new FlowLayoutPanel { FlowDirection = FlowDirection.LeftToRight, AutoSize = true };
        mirrorPanel.Controls.Add(_mirrorCheck);
        mirrorPanel.Controls.Add(new Label { Text = "FPS:", TextAlign = ContentAlignment.MiddleLeft, AutoSize = true });
        mirrorPanel.Controls.Add(_fpsSlider);
        mirrorPanel.Controls.Add(new Label { Text = $"{_fpsSlider.Value}", Width = 24, TextAlign = ContentAlignment.MiddleLeft });
        table.Controls.Add(mirrorPanel, 1, 2);

        // Row 3: status
        table.Controls.Add(new Label { Text = "Status:", TextAlign = ContentAlignment.MiddleLeft, AutoSize = true }, 0, 3);
        table.Controls.Add(_statusLabel, 1, 3);

        // Row 4: client
        table.Controls.Add(new Label { Text = "Client:", TextAlign = ContentAlignment.MiddleLeft, AutoSize = true }, 0, 4);
        table.Controls.Add(_clientLabel, 1, 4);

        // Row 5: video
        table.Controls.Add(new Label { Text = "Video:", TextAlign = ContentAlignment.MiddleLeft, AutoSize = true }, 0, 5);
        table.Controls.Add(_videoLabel, 1, 5);

        // Row 6: backend + topmost
        table.Controls.Add(new Label { Text = "Backend:", TextAlign = ContentAlignment.MiddleLeft, AutoSize = true }, 0, 6);
        var bottomRow = new FlowLayoutPanel { FlowDirection = FlowDirection.LeftToRight, AutoSize = true };
        bottomRow.Controls.Add(_backendLabel);
        bottomRow.Controls.Add(_topMostCheck);
        table.Controls.Add(bottomRow, 1, 6);

        // Row 7: PC IP
        table.Controls.Add(new Label { Text = "PC IP:", TextAlign = ContentAlignment.MiddleLeft, AutoSize = true }, 0, 7);
        table.Controls.Add(_ipLabel, 1, 7);

        // Row 8: log
        table.SetColumnSpan(_logBox, 2);
        table.Controls.Add(_logBox, 0, 8);
        _logBox.Dock = DockStyle.Fill;

        Controls.Add(table);
    }

    private void WireEvents()
    {
        _startStopBtn.Click += (_, _) =>
        {
            if (_server.IsRunning)
                StopAll();
            else
                StartAll();
        };

        _topMostCheck.CheckedChanged += (_, _) =>
            TopMost = _topMostCheck.Checked;

        _mirrorCheck.CheckedChanged += (_, _) =>
        {
            _videoPortInput.Enabled = _mirrorCheck.Checked;
            _fpsSlider.Enabled = _mirrorCheck.Checked;
        };

        _fpsSlider.ValueChanged += (_, _) =>
        {
            if (_fpsSlider.Parent?.Controls[^1] is Label fpsLabel)
                fpsLabel.Text = $"{_fpsSlider.Value}";
            _screenStreamer.TargetFps = _fpsSlider.Value;
        };

        _portInput.ValueChanged += (_, _) => UpdateServerPort();
        _videoPortInput.ValueChanged += (_, _) => UpdateVideoPort();

        _adbWifiBtn.Click += (_, _) => EnableAdbWifi();

        _server.OnStarted += () => this.Invoke(() => _server_OnStarted());
        _server.OnStopped += () => this.Invoke(() => _server_OnStopped());
        _server.OnClientConnected += (ep) => this.Invoke(() => _server_OnClientConnected(ep));
        _server.OnClientDisconnected += () => this.Invoke(() => _server_OnClientDisconnected());
        _server.OnLog += (msg) => this.Invoke(() => AppendLog(msg));

        _btServer.OnStarted += () => this.Invoke(() => _server_OnStarted());
        _btServer.OnStopped += () => this.Invoke(() => _server_OnStopped());
        _btServer.OnClientConnected += (name) => this.Invoke(() => _server_OnClientConnected($"BT: {name}"));
        _btServer.OnClientDisconnected += () => this.Invoke(() => _server_OnClientDisconnected_Bt());
        _btServer.OnLog += (msg) => this.Invoke(() => AppendLog(msg));

        _screenStreamer.OnStarted += () => this.Invoke(() =>
            _videoLabel.Text = "Streaming");
        _screenStreamer.OnStopped += () => this.Invoke(() =>
            _videoLabel.Text = "Off");
        _screenStreamer.OnLog += (msg) => this.Invoke(() => AppendLog(msg));
    }

    private void StartAll()
    {
        SaveSettings();
        UpdateServerPort();
        UpdateVideoPort();

        var controlPort = (int)_portInput.Value;
        var videoPort = (int)_videoPortInput.Value;

        if (_modeSelector.SelectedIndex == 2) // Bluetooth
        {
            _btServer.Start();
            return;
        }

        if (IsAdmin())
            EnsureFirewallRules(controlPort, videoPort);

        _server.Start();

        if (_mirrorCheck.Checked)
        {
            _screenStreamer.TargetFps = _fpsSlider.Value;
            _screenStreamer.Start();
        }

        if (_modeSelector.SelectedIndex == 1) // USB (ADB)
            RunAdbReverse(controlPort, videoPort);
    }

    private void StopAll()
    {
        _screenStreamer.Stop();
        _server.Stop();
        _btServer.Stop();
    }

    private void _server_OnStarted()
    {
        _startStopBtn.Text = "Stop";
        _startStopBtn.BackColor = Color.IndianRed;
        _startStopBtn.ForeColor = Color.White;
        _portInput.Enabled = false;
        _videoPortInput.Enabled = false;
        _modeSelector.Enabled = false;
        _mirrorCheck.Enabled = false;
        UpdateStatus("Listening", Color.Green);
    }

    private void _server_OnStopped()
    {
        _startStopBtn.Text = "Start";
        _startStopBtn.BackColor = SystemColors.Control;
        _startStopBtn.ForeColor = SystemColors.ControlText;
        _portInput.Enabled = true;
        _videoPortInput.Enabled = _mirrorCheck.Checked;
        _modeSelector.Enabled = true;
        _mirrorCheck.Enabled = true;
        _clientLabel.Text = "Disconnected";
        _videoLabel.Text = "Off";
        UpdateStatus("Stopped", Color.Gray);
    }

    private void _server_OnClientConnected(string info)
    {
        _clientLabel.Text = $"Connected: {info}";
        _clientLabel.ForeColor = Color.Green;
        WindowState = FormWindowState.Minimized;
    }

    private async void _server_OnClientDisconnected()
    {
        _clientLabel.Text = "Disconnected";
        _clientLabel.ForeColor = Color.Gray;
        WindowState = FormWindowState.Normal;

        if (_modeSelector.SelectedIndex == 1 && _server.IsRunning)
        {
            await Task.Delay(2000);
            RunAdbReverse((int)_portInput.Value, (int)_videoPortInput.Value);
        }
    }

    private void _server_OnClientDisconnected_Bt()
    {
        _clientLabel.Text = "Disconnected";
        _clientLabel.ForeColor = Color.Gray;
        WindowState = FormWindowState.Normal;
    }

    private void EnableAdbWifi()
    {
        AppendLog("Włączam ADB przez WiFi (port 5555)...");
        var result = RunWithOutput("adb", "tcpip 5555");
        AppendLog($"adb tcpip 5555: {(string.IsNullOrWhiteSpace(result) ? "OK" : result)}");

        // Show device IP so user knows what to type in Boox app
        var ip = RunWithOutput("adb", "shell ip route");
        var match = System.Text.RegularExpressions.Regex.Match(ip, @"src (\d+\.\d+\.\d+\.\d+)");
        if (match.Success)
            AppendLog($"IP tabletu: {match.Groups[1].Value}  (wpisz to w aplikacji Boox)");
    }

    private void UpdateServerPort()
    {
        if (!_server.IsRunning)
            _server.UpdatePort((int)_portInput.Value);
    }

    private void UpdateVideoPort()
    {
        if (!_screenStreamer.IsRunning)
            _screenStreamer.UpdatePort((int)_videoPortInput.Value);
    }

    private void AppendLog(string msg)
    {
        _logBox.AppendText($"[{DateTime.Now:HH:mm:ss.fff}] {msg}{Environment.NewLine}");
        if (_logBox.TextLength > 80_000)
            _logBox.Text = _logBox.Text[40_000..];
    }

    private void UpdateStatus(string text, Color color)
    {
        _statusLabel.Text = text;
        _statusLabel.ForeColor = color;
    }

    private static bool IsAdmin()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }

    private static string GetLocalIps()
    {
        var ips = Dns.GetHostAddresses(Dns.GetHostName())
            .Where(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a))
            .Select(a => a.ToString());
        return string.Join("  |  ", ips);
    }

    private static void RunSilent(string exe, string args)
    {
        try
        {
            using var p = Process.Start(new ProcessStartInfo(exe, args)
            {
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            });
            p?.WaitForExit(4000);
        }
        catch { }
    }

    private string RunWithOutput(string exe, string args)
    {
        try
        {
            using var p = Process.Start(new ProcessStartInfo(exe, args)
            {
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            });
            if (p == null) return "(failed to start)";
            var stdout = p.StandardOutput.ReadToEnd();
            var stderr = p.StandardError.ReadToEnd();
            p.WaitForExit(4000);
            return (stdout + stderr).Trim();
        }
        catch (Exception ex) { return ex.Message; }
    }

    private void EnsureFirewallRules(int controlPort, int videoPort)
    {
        RunSilent("netsh", "advfirewall firewall delete rule name=\"Boox Tablet Driver\"");
        RunSilent("netsh", $"advfirewall firewall add rule name=\"Boox Tablet Driver\" dir=in action=allow protocol=TCP localport={controlPort},{videoPort}");
        AppendLog($"Firewall rules created for ports {controlPort},{videoPort}");
    }

    private void RunAdbReverse(int controlPort, int videoPort)
    {
        AppendLog("Running adb reverse (USB mode)...");
        var r1 = RunWithOutput("adb", $"reverse tcp:{controlPort} tcp:{controlPort}");
        var r2 = RunWithOutput("adb", $"reverse tcp:{videoPort} tcp:{videoPort}");
        AppendLog($"adb reverse ctrl: {(string.IsNullOrEmpty(r1) ? "OK" : r1)}");
        AppendLog($"adb reverse video: {(string.IsNullOrEmpty(r2) ? "OK" : r2)}");
    }

    private static string DescribeBackend(InjectorBackend b) => b switch
    {
        InjectorBackend.Touch => "Touch Injection (nacisk)",
        InjectorBackend.Mouse => "SendInput (mysz, brak nacisku)",
        _ => "Brak",
    };

    private void SaveSettings()
    {
        try
        {
            var s = new
            {
                port      = (int)_portInput.Value,
                videoPort = (int)_videoPortInput.Value,
                mode      = _modeSelector.SelectedIndex,
                fps       = _fpsSlider.Value,
                mirror    = _mirrorCheck.Checked,
            };
            File.WriteAllText(SettingsPath, System.Text.Json.JsonSerializer.Serialize(s));
        }
        catch { }
    }

    private void LoadSettings()
    {
        try
        {
            if (!File.Exists(SettingsPath)) return;
            using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(SettingsPath));
            var r = doc.RootElement;
            if (r.TryGetProperty("port",      out var p))   _portInput.Value           = Math.Clamp(p.GetInt32(),   1024, 65535);
            if (r.TryGetProperty("videoPort", out var vp))  _videoPortInput.Value      = Math.Clamp(vp.GetInt32(),  1024, 65535);
            if (r.TryGetProperty("mode",      out var m))   _modeSelector.SelectedIndex = Math.Clamp(m.GetInt32(),  0, 2);
            if (r.TryGetProperty("fps",       out var fps)) _fpsSlider.Value            = Math.Clamp(fps.GetInt32(), 1, 25);
            if (r.TryGetProperty("mirror",    out var mir)) _mirrorCheck.Checked        = mir.GetBoolean();
        }
        catch { }
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        _screenStreamer.Dispose();
        _server.Dispose();
        _btServer.Dispose();
        _injector.Dispose();
        base.OnFormClosing(e);
    }
}
