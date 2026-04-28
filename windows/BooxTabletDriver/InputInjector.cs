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
    private bool _touchSupported;

    // ── Screen info ────────────────────────────────────────────────────
    private int _screenW;
    private int _screenH;

    // ── Config ─────────────────────────────────────────────────────────
    public InjectorBackend Backend { get; private set; } = InjectorBackend.None;

    // ── Win32 constants ────────────────────────────────────────────────
    private const uint INPUT_MOUSE = 0;
    private const uint MOUSEEVENTF_MOVE = 0x0001;
    private const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;

    private const uint POINTER_FLAG_INRANGE   = 0x00000002;
    private const uint POINTER_FLAG_INCONTACT = 0x00000004;
    private const uint POINTER_FLAG_DOWN      = 0x00010000;
    private const uint POINTER_FLAG_UPDATE    = 0x00020000;
    private const uint POINTER_FLAG_UP        = 0x00040000;

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

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public MOUSEINPUT mi;
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
    public void PenDown(float x, float y, float pressure)
    {
        if (Backend == InjectorBackend.Touch)
            InjectTouchDown(x, y, pressure);
        if (Backend == InjectorBackend.Mouse)  // also catches auto-fallback from touch
            InjectMouseDown(x, y);
        _penDown = true;
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
            InjectMouseUp();
        _penDown = false;
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
    private void InjectMouseDown(float x, float y)
    {
        SendMouseEvent(x, y, MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_MOVE | MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_VIRTUALDESK);
    }

    private void InjectMouseMove(float x, float y)
    {
        var flags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_MOVE | MOUSEEVENTF_VIRTUALDESK;
        if (_penDown) flags |= MOUSEEVENTF_LEFTDOWN;
        SendMouseEvent(x, y, flags);
    }

    private void InjectMouseUp()
    {
        SendMouseEvent(0, 0, MOUSEEVENTF_LEFTUP);
    }

    private void SendMouseEvent(float x, float y, uint flags)
    {
        var absX = (int)(x / _screenW * 65535);
        var absY = (int)(y / _screenH * 65535);

        var input = new INPUT
        {
            type = INPUT_MOUSE,
            mi = new MOUSEINPUT
            {
                dx = absX,
                dy = absY,
                dwFlags = flags,
            }
        };

        SendInput(1, [input], Marshal.SizeOf<INPUT>());
    }

    // ── Helpers ────────────────────────────────────────────────────────
    private (int x, int y) MapCoords(float tabletX, float tabletY)
    {
        var x = (int)(tabletX / 2200 * _screenW);  // 2200 = Boox Tab X C width
        var y = (int)(tabletY / 1650 * _screenH);  // 1650 = Boox Tab X C height
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

    public void Dispose()
    {
        if (_penDown) PenUp();
    }
}
