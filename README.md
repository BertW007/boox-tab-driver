# Boox Tab X C — Graphics Tablet for Windows

Zamienia **Boox Tab X C** w tablet graficzny dla Windows.

- **Rysik** → sterowanie kursorem z czułością nacisku
- **Ekran Windows** → podgląd na Boox (mirrorowanie)
- **Transport** → WiFi, USB (ADB), Bluetooth

## Architektura

```
┌─ Boox Tab X C (Flutter) ─────────────────┐       ┌─ Windows PC (C# WinForms) ────────┐
│                                           │ TCP   │                                   │
│  ┌─────────────────────────────────────┐  │◄─────►│  TabletServer (:52017)            │
│  │         Screen preview ▲            │  │ pen   │     ↓ odbiera zdarzenia rysika    │
│  │                        │            │  │ events│  InputInjector                   │
│  │  ┌─── rysunek ────┐    │            │  │       │     ↓ Touch Injection / SendInput│
│  │  │  Linie rysika  │    │ JPEG frames│  │       │                                   │
│  │  └────────────────┘    │            │  │◄──────│  ScreenStreamer (:52018)          │
│  │                        ▼            │  │ video │     ↓ przechwytuje ekran          │
│  │  ┌──────────────────────────────┐   │  │       │     ↓ wysyła JPEG klatki          │
│  │  │  Obraz z Windows (Image)     │   │  │       │                                   │
│  │  └──────────────────────────────┘   │  │       │                                   │
│  └─────────────────────────────────────┘  │       └───────────────────────────────────┘
```

## Transporty

| Transport | Opis | Wymagania |
|-----------|------|-----------|
| **WiFi** | TCP/IP przez sieć lokalną | Boox i PC w tej samej sieci |
| **USB (ADB)** | TCP przez ADB reverse forward | Kabel USB, ADB, debugowanie USB na Boox |
| **Bluetooth** | RFCOMM (w budowie) | Sparowane urządzenia |

## Funkcje

- **Czułość nacisku** — Touch Injection API (Windows 8+), z fallbackiem do myszy
- **Mirrorowanie ekranu** — podgląd pulpitu Windows na Boox w ~12 FPS (regulowany)
- **Wizualne informacje zwrotne** — linie rysika widoczne na ekranie Boox
- **Auto-detect backendu** — Touch Injection jeśli dostępny, inaczej SendInput

## Budowanie

### Android (Flutter)

```bash
cd android_flutter

# Inicjalizacja projektu (pierwszy raz)
flutter create --project-name boox_tablet .

# Nadpisz pliki w lib/ (skopiuj z repozytorium)

# Dodaj uprawnienia do android/app/src/main/AndroidManifest.xml:
#   <uses-permission android:name="android.permission.INTERNET"/>
#   (plik android_app_manifest.xml zawiera wszystkie potrzebne uprawnienia)

# Buduj APK
flutter build apk --release
```

APK: `build/app/outputs/flutter-apk/app-release.apk`

**Wymagania:** Flutter SDK 3.0+, Android SDK 26+

### Windows (C#)

```bash
cd windows/BooxTabletDriver

# Budowanie
dotnet build -c Release

# Publikacja (standalone, wymaga admin)
dotnet publish -c Release -r win-x64 --self-contained true
```

EXE: `bin/Release/net8.0-windows/win-x64/publish/BooxTabletDriver.exe`

**Wymagania:** .NET 8 SDK, Windows 10/11 64-bit

## Użycie

### 1. Uruchom serwer na Windows
- Uruchom **BooxTabletDriver.exe** jako **Administrator** (konieczne dla Touch Injection)
- Ustaw port sterowania (domyślnie **52017**) i port wideo (domyślnie **52018**)
- Włącz **Screen mirroring** jeśli chcesz podgląd ekranu
- Kliknij **Start**

### 2. Połącz Booxa

**WiFi:**
- Boox i PC w tej samej sieci
- W aplikacji na Boox wybierz **WiFi**, wpisz IP komputera
- Kliknij **Connect to PC**

**USB (ADB):**
- Podłącz Boox kablem USB
- Włącz **Opcje deweloperskie → Debugowanie USB** na Boox
- Na PC uruchom:
  ```bash
  adb reverse tcp:52017 tcp:52017
  adb reverse tcp:52018 tcp:52018
  ```
- W aplikacji na Boox wybierz **USB** i kliknij **Connect**

### 3. Rysuj!
- Po połączeniu rysik steruje kursorem Windows
- Nacisk jest przesyłany — programy jak Krita, Photoshop rozpoznają go
- Na Boox widzisz ekran Windows i swoje pociągnięcia

## Protokół

### Sterowanie (Android → Windows, port kontrolny)
```
{"type":"pen","x":100.0,"y":200.0,"pressure":0.75,"action":"down","tool":"stylus"}
```

### Wideo (Windows → Android, port wideo)
```
[4 bajty LE: rozmiar klatki][dane JPEG]
```

## Pliki projektu

```
android_flutter/          ← Aplikacja na Boox (Flutter/Dart)
├── lib/
│   ├── main.dart                        # Entry point
│   ├── models/pen_event.dart            # Model zdarzenia rysika
│   ├── services/tablet_connection.dart  # Połączenie TCP + wideo
│   └── screens/home_screen.dart         # UI: panel + canvas + mirror
├── android_app_manifest.xml             # Uprawnienia Androida
└── pubspec.yaml

windows/BooxTabletDriver/ ← Serwer Windows (C# .NET 8)
├── Program.cs                           # Entry point
├── MainForm.cs                          # WinForms UI
├── InputInjector.cs                     # Touch Injection API
├── TabletServer.cs                      # Serwer TCP (sterowanie)
└── ScreenStreamer.cs                    # Strumieniowanie ekranu (JPEG)
```

## Uwagi

- Wymaga uruchomienia jako **Administrator** dla Touch Injection (czułość nacisku).
- Jeśli Touch Injection niedostępny → automatyczny fallback do myszy (bez nacisku).
- Boox Tab X C: 2200×1650 px — współrzędne mapowane proporcjonalnie na pulpit Windows.
- Dla niskiej latencji rysika zalecane WiFi 5 GHz lub USB (ADB).
- Mirrorowanie ekranu działa w ~8–15 FPS — wystarczające dla podglądu, nie dla wideo.
- `FlutterBluetoothSerial` wymaga odkomentowania w `pubspec.yaml` i konfiguracji na Windows.
