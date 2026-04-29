using System.Runtime.InteropServices;

namespace BooxTabletDriver;

enum InjectorBackend { Mouse, Touch, None }

/// <summary>
/// Injects pointer input into Windows.
/// Primary: Touch Injection API (supports pressure, Win 8+).
/// Fallback: SendInput mouse (no pressure, works everywhere).
/// </summary>
sealed class InputInjector : IDisposable
{
    // ── Touch injection state ──────────────────────────────────────────
    private bool _touchInited;
    private uint _pointerId = 0;
    private bool _penDown;
    private string _penButton = "primary";
    private bool _touchSupported;

    // ── Screen info ────────────────────────────────────────────────────
    private int _screenW;
    private int _screenH;

    // ── Config ─────────────────────────────────────────────────────────
    public InjectorBackend Backend { get; private set; } = InjectorBackend.None;

    // ── Win32 constants ────────────────────────────────────────────────
    private const uint INPUT_MOUSE    = 0;
    private const uint INPUT_KEYBOARD = 1;
    private const uint MOUSEEVENTF_MOVE        = 0x0001;
    private const uint MOUSEEVENTF_LEFTDOWN    = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP      = 0x0004;
    private const uint MOUSEEVENTF_RIGHTDOWN   = 0x0008;
    private const uint MOUSEEVENTF_RIGHTUP     = 0x0010;
    private const uint MOUSEEVENTF_MIDDLEDOWN  = 0x0020;
    private const uint MOUSEEVENTF_MIDDLEUP    = 0x0040;
    private const uint MOUSEEVENTF_WHEEL       = 0x0800;
    private const uint MOUSEEVENTF_HWHEEL      = 0x1000;
    private const uint MOUSEEVENTF_ABSOLUTE    = 0x8000;
    private const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;

    private const uint POINTER_FLAG_INRANGE   = 0x00000002;
    private const uint POINTER_FLAG_INCONTACT = 0x00000004;
    private const uint POINTER_FLAG_DOWN      = 0x00010000;
    private const uint POINTER_FLAG_UPDATE    = 0x00020000;
    private const uint POINTER_FLAG_UP        = 0x00040000;

    private const uint KEYEVENTF_KEYUP   = 0x0002;
    private const uint KEYEVENTF_UNICODE = 0x0004;

    private const uint TOUCH_FEEDBACK_DEFAULT = 1;
    private const uint TOUCH_MASK_CONTACTAREA = 0x00000001;
    private const uint TOUCH_MASK_PRESSURE    = 0x00000004;

    // ── Structs ────────────────────────────────────────────────────────
    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int x; public int y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINTER_INFO
    {
        public uint pointerType;
        public uint pointerId;
        public uint frameId;
        public uint pointerFlags;
        public nint sourceDevice;
        public nint hwndTarget;
        public POINT ptPixelLocation;
        public POINT ptHimetricLocation;
        public POINT ptPixelLocationRaw;
        public POINT ptHimetricLocationRaw;
        public uint dwTime;
        public uint historyCount;
        public int inputData;
        public uint dwKeyStates;
        public ulong PerformanceCount;
        public int ButtonChangeType;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int left; public int top; public int right; public int bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINTER_TOUCH_INFO
    {
        public POINTER_INFO pointerInfo;
        public int touchFlags;
        public uint touchMask;
        public RECT contactArea;
        public RECT contactAreaRaw;
        public uint orientation;
        public uint pressure;
    }

    // INPUT is a C union — use Explicit layout so both mi and ki occupy the same memory.
    // On x64: type(4) + 4-byte padding + union(32) = 40 bytes total.
    [StructLayout(LayoutKind.Explicit, Size = 40)]
    private struct INPUT
    {
        [FieldOffset(0)] public uint type;
        [FieldOffset(8)] public MOUSEINPUT mi;
        [FieldOffset(8)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public nint dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public nint dwExtraInfo;
    }

    // ── P/Invoke ───────────────────────────────────────────────────────
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool InitializeTouchInjection(uint maxCount, uint dwMode);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool InjectTouchInput(uint count, [In] POINTER_TOUCH_INFO[] contacts);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint cInputs, [In] INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    private static extern nint GetForegroundWindow();

    // ── Initialisation ─────────────────────────────────────────────────
    public void Initialize()
    {
        _screenW = Screen.PrimaryScreen!.Bounds.Width;
        _screenH = Screen.PrimaryScreen!.Bounds.Height;

        // Try touch injection first
        try
        {
            _touchInited = InitializeTouchInjection(10, TOUCH_FEEDBACK_DEFAULT);
            _touchSupported = _touchInited;
        }
        catch
        {
            _touchSupported = false;
        }

        if (_touchSupported)
        {
            Backend = InjectorBackend.Touch;
            DebugLog("Touch Injection initialised");
        }
        else
        {
            Backend = InjectorBackend.Mouse;
            DebugLog("Touch unavailable, falling back to mouse (SendInput)");
        }
    }

    // ── Public API ─────────────────────────────────────────────────────
    public void PenDown(float x, float y, float pressure, string button = "primary")
    {
        if (Backend == InjectorBackend.Touch && button == "primary")
            InjectTouchDown(x, y, pressure);
        if (Backend == InjectorBackend.Mouse)
            InjectMouseDown(x, y, button);
        _penDown = true;
        _penButton = button;
    }

    public void PenMove(float x, float y, float pressure)
    {
        if (Backend == InjectorBackend.Touch)
            InjectTouchMove(x, y, pressure);
        if (Backend == InjectorBackend.Mouse)
            InjectMouseMove(x, y);
    }

    public void PenUp()
    {
        if (Backend == InjectorBackend.Touch)
            InjectTouchUp();
        if (Backend == InjectorBackend.Mouse)
            InjectMouseUp(_penButton);
        _penDown = false;
        _penButton = "primary";
    }

    public void InjectScroll(float x, float y, float dx, float dy)
    {
        var (px, py) = MapCoords(x, y);
        // Move cursor to scroll position first
        SendMouseEvent(px, py, MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_MOVE | MOUSEEVENTF_VIRTUALDESK, 0);
        // Vertical scroll: Flutter positive dy = scroll down, Windows negative = scroll down
        if (dy != 0)
        {
            var delta = (int)(-dy * 1.5f);
            SendMouseEvent(0, 0, MOUSEEVENTF_WHEEL, (uint)delta);
        }
        if (dx != 0)
        {
            var delta = (int)(dx * 1.5f);
            SendMouseEvent(0, 0, MOUSEEVENTF_HWHEEL, (uint)delta);
        }
    }

    // ── Touch injection ────────────────────────────────────────────────
    private void InjectTouchDown(float x, float y, float pressure)
    {
        var (px, py) = MapCoords(x, y);
        var info = MakeTouchInfo(px, py, pressure, POINTER_FLAG_DOWN | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT);
        InjectTouchInfo(info);
    }

    private void InjectTouchMove(float x, float y, float pressure)
    {
        var (px, py) = MapCoords(x, y);
        var flags = POINTER_FLAG_UPDATE | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT;
        var info = MakeTouchInfo(px, py, pressure, flags);
        InjectTouchInfo(info);
    }

    private void InjectTouchUp()
    {
        var info = MakeTouchInfo(0, 0, 0, POINTER_FLAG_UP);
        InjectTouchInfo(info);
    }

    public event Action<string>? OnError;

    private void InjectTouchInfo(POINTER_TOUCH_INFO info)
    {
        if (!InjectTouchInput(1, [info]))
        {
            var err = Marshal.GetLastPInvokeError();
            if (err == 0x57) // ERROR_INVALID_PARAMETER — likely no touch HW
            {
                Backend = InjectorBackend.Mouse;
                OnError?.Invoke("Touch injection unavailable (brak sprzętu touch?), przełączam na Mouse");
            }
            else
            {
                OnError?.Invoke($"InjectTouchInput failed (0x{err:X})");
            }
        }
    }

    private POINTER_TOUCH_INFO MakeTouchInfo(int x, int y, float pressure, uint flags)
    {
        return new POINTER_TOUCH_INFO
        {
            pointerInfo = new POINTER_INFO
            {
                pointerType = 2, // PT_TOUCH
                pointerId = _pointerId,
                pointerFlags = flags,
                ptPixelLocation = new POINT { x = x, y = y },
                ptHimetricLocation = new POINT { x = x * 100 / 96, y = y * 100 / 96 },
                ptPixelLocationRaw = new POINT { x = x, y = y },
                ptHimetricLocationRaw = new POINT { x = x * 100 / 96, y = y * 100 / 96 },
            },
            touchMask = TOUCH_MASK_CONTACTAREA | TOUCH_MASK_PRESSURE,
            pressure = (uint)(pressure * 1024),
            contactArea = new RECT { left = x - 4, top = y - 4, right = x + 4, bottom = y + 4 },
            contactAreaRaw = new RECT { left = x - 4, top = y - 4, right = x + 4, bottom = y + 4 },
        };
    }

    // ── Mouse fallback ─────────────────────────────────────────────────
    private void InjectMouseDown(float x, float y, string button = "primary")
    {
        var (px, py) = MapCoords(x, y);
        var downFlag = button switch {
            "secondary" => MOUSEEVENTF_RIGHTDOWN,
            "middle"    => MOUSEEVENTF_MIDDLEDOWN,
            _           => MOUSEEVENTF_LEFTDOWN,
        };
        SendMouseEvent(px, py, MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_MOVE | downFlag | MOUSEEVENTF_VIRTUALDESK, 0);
    }

    private void InjectMouseMove(float x, float y)
    {
        var (px, py) = MapCoords(x, y);
        var flags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_MOVE | MOUSEEVENTF_VIRTUALDESK;
        if (_penDown)
        {
            flags |= _penButton switch {
                "secondary" => MOUSEEVENTF_RIGHTDOWN,
                "middle"    => MOUSEEVENTF_MIDDLEDOWN,
                _           => MOUSEEVENTF_LEFTDOWN,
            };
        }
        SendMouseEvent(px, py, flags, 0);
    }

    private void InjectMouseUp(string button = "primary")
    {
        var upFlag = button switch {
            "secondary" => MOUSEEVENTF_RIGHTUP,
            "middle"    => MOUSEEVENTF_MIDDLEUP,
            _           => MOUSEEVENTF_LEFTUP,
        };
        SendMouseEvent(0, 0, upFlag, 0);
    }

    private void SendMouseEvent(int x, int y, uint flags, uint mouseData)
    {
        var absX = (flags & MOUSEEVENTF_ABSOLUTE) != 0 ? (int)((float)x / _screenW * 65535) : 0;
        var absY = (flags & MOUSEEVENTF_ABSOLUTE) != 0 ? (int)((float)y / _screenH * 65535) : 0;

        var input = new INPUT
        {
            type = INPUT_MOUSE,
            mi = new MOUSEINPUT
            {
                dx = absX,
                dy = absY,
                mouseData = mouseData,
                dwFlags = flags,
            }
        };

        SendInput(1, [input], Marshal.SizeOf<INPUT>());
    }

    // ── Shortcut injection ────────────────────────────────────────────
    public void InjectShortcut(string name)
    {
        switch (name)
        {
            case "esc":        Tap(0x1B);                break;  // Escape
            case "snip":       Combo(0xA0, 0x5B, 0x53); break;  // Shift+Win+S
            case "printscreen":Tap(0x2C);                break;  // PrintScreen
            case "copy":       Combo(0xA2, 0x43);        break;  // Ctrl+C
            case "paste":      Combo(0xA2, 0x56);        break;  // Ctrl+V
            case "tab":        Tap(0x09);                break;  // Tab
            case "taskview":   Combo(0x5B, 0x09);        break;  // Win+Tab
            case "alttab":     Combo(0xA4, 0x09);        break;  // Alt+Tab
        }
    }

    // Tap a single key
    private void Tap(ushort vk)
    {
        SendKeyEvent(vk, 0, 0);
        SendKeyEvent(vk, 0, KEYEVENTF_KEYUP);
    }

    // Hold all keys in order, release in reverse
    private void Combo(params ushort[] vks)
    {
        foreach (var vk in vks)
            SendKeyEvent(vk, 0, 0);
        foreach (var vk in vks.Reverse())
            SendKeyEvent(vk, 0, KEYEVENTF_KEYUP);
    }

    // ── Keyboard injection ─────────────────────────────────────────────
    private static readonly Dictionary<string, ushort> _keyLabelToVk = new()
    {
        ["Backspace"]   = 0x08, ["Tab"]         = 0x09, ["Enter"]       = 0x0D,
        ["Escape"]      = 0x1B, ["Space"]        = 0x20, ["Delete"]      = 0x2E,
        ["Insert"]      = 0x2D, ["Home"]         = 0x24, ["End"]         = 0x23,
        ["Page Up"]     = 0x21, ["Page Down"]    = 0x22,
        ["Arrow Left"]  = 0x25, ["Arrow Up"]     = 0x26,
        ["Arrow Right"] = 0x27, ["Arrow Down"]   = 0x28,
        ["Caps Lock"]   = 0x14, ["Num Lock"]     = 0x90, ["Scroll Lock"] = 0x91,
        ["Print Screen"]= 0x2C, ["Pause"]        = 0x13,
        ["Shift Left"]  = 0xA0, ["Shift Right"]  = 0xA1,
        ["Control Left"]= 0xA2, ["Control Right"]= 0xA3,
        ["Alt Left"]    = 0xA4, ["Alt Right"]    = 0xA5,
        ["Meta Left"]   = 0x5B, ["Meta Right"]   = 0x5C,
        ["F1"]  = 0x70, ["F2"]  = 0x71, ["F3"]  = 0x72, ["F4"]  = 0x73,
        ["F5"]  = 0x74, ["F6"]  = 0x75, ["F7"]  = 0x76, ["F8"]  = 0x77,
        ["F9"]  = 0x78, ["F10"] = 0x79, ["F11"] = 0x7A, ["F12"] = 0x7B,
    };

    public void InjectKey(string action, string ch, string label)
    {
        var isDown = action == "down";
        var upFlag = isDown ? 0u : KEYEVENTF_KEYUP;

        // Printable Unicode character — inject directly (bypasses layout mapping)
        if (ch.Length == 1 && ch[0] >= 0x20 && ch[0] != 0x7F)
        {
            SendKeyEvent(0, (ushort)ch[0], KEYEVENTF_UNICODE | upFlag);
            return;
        }

        // Special key: look up Windows VK by Flutter key label
        if (_keyLabelToVk.TryGetValue(label, out var vk))
        {
            SendKeyEvent(vk, 0, upFlag);
            return;
        }

        // Single ASCII letter or digit (e.g. Ctrl+C sends label="c", char empty)
        if (label.Length == 1)
        {
            var c = char.ToUpper(label[0]);
            if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
                SendKeyEvent((ushort)c, 0, upFlag);
        }
    }

    private void SendKeyEvent(ushort vk, ushort scan, uint flags)
    {
        var input = new INPUT
        {
            type = INPUT_KEYBOARD,
            ki = new KEYBDINPUT { wVk = vk, wScan = scan, dwFlags = flags },
        };
        SendInput(1, [input], Marshal.SizeOf<INPUT>());
    }

    // ── Helpers ────────────────────────────────────────────────────────
    private (int x, int y) MapCoords(float tabletX, float tabletY)
    {
        // tabletX/Y are normalized 0.0–1.0 (fraction of canvas size)
        var x = (int)(tabletX * _screenW);
        var y = (int)(tabletY * _screenH);
        return (Math.Clamp(x, 0, _screenW), Math.Clamp(y, 0, _screenH));
    }

    public void UpdateScreenSize()
    {
        _screenW = Screen.PrimaryScreen!.Bounds.Width;
        _screenH = Screen.PrimaryScreen!.Bounds.Height;
    }

    private static void DebugLog(string msg)
    {
        System.Diagnostics.Debug.WriteLine($"[InputInjector] {msg}");
    }

    public void ReleaseAll()
    {
        if (_penDown) PenUp();
        ushort[] modifiers = [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x5B, 0x5C]; // Shift, Ctrl, Alt, Win
        foreach (var vk in modifiers)
            SendKeyEvent(vk, 0, KEYEVENTF_KEYUP);
        // Release mouse buttons in case they're stuck
        SendMouseEvent(0, 0, MOUSEEVENTF_LEFTUP | MOUSEEVENTF_RIGHTUP | MOUSEEVENTF_MIDDLEUP, 0);
    }

    public void ReleaseAllModifiers() => ReleaseAll();

    public void Dispose()
    {
        ReleaseAll();
    }
}
