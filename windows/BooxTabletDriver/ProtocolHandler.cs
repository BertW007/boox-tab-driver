using System.Text.Json;

namespace BooxTabletDriver;

static class ProtocolHandler
{
    public static void Process(string json, InputInjector injector, Action<string> log)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var type = root.GetProperty("type").GetString();

            if (type == "key")
            {
                var action = root.GetProperty("action").GetString() ?? "down";
                var ch    = root.TryGetProperty("char",  out var cP) ? cP.GetString() ?? "" : "";
                var label = root.TryGetProperty("label", out var lP) ? lP.GetString() ?? "" : "";
                injector.InjectKey(action, ch, label);
                return;
            }

            if (type == "shortcut")
            {
                var name = root.TryGetProperty("name", out var nP) ? nP.GetString() ?? "" : "";
                injector.InjectShortcut(name);
                return;
            }

            if (type == "scroll")
            {
                var sx = root.TryGetProperty("x",  out var sxP) ? sxP.GetSingle() : 0f;
                var sy = root.TryGetProperty("y",  out var syP) ? syP.GetSingle() : 0f;
                var dx = root.TryGetProperty("dx", out var dxP) ? dxP.GetSingle() : 0f;
                var dy = root.TryGetProperty("dy", out var dyP) ? dyP.GetSingle() : 0f;
                injector.InjectScroll(sx, sy, dx, dy);
                return;
            }

            if (type != "pen") return;

            var penAction = root.GetProperty("action").GetString() ?? "move";
            var x = root.GetProperty("x").GetSingle();
            var y = root.GetProperty("y").GetSingle();
            var pressure = root.GetProperty("pressure").GetSingle();
            var button = root.TryGetProperty("button", out var btnP) ? btnP.GetString() ?? "primary" : "primary";

            if (penAction == "down")
                log($"Pen down x={x:F3} y={y:F3} p={pressure:F2} btn={button}");

            switch (penAction)
            {
                case "down":  injector.PenDown(x, y, pressure, button); break;
                case "move":  injector.PenMove(x, y, pressure);         break;
                case "up":    injector.PenUp();                          break;
            }
        }
        catch (JsonException ex) { log($"JSON parse error: {ex.Message}"); }
        catch (Exception ex)     { log($"Process error: {ex.Message}");    }
    }
}
