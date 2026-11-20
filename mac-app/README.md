# mac-app

Native SwiftUI macOS app: reads the Arduino's serial stream and draws respiration, GSR and pulse as a live scrolling strip chart.

## Run

Requires macOS 14+ and Xcode (or the Swift toolchain).

```sh
cd mac-app
swift run
```

Or open `mac-app/Package.swift` in Xcode and press Run.

- **No hardware?** Click **Simulate** to stream generated respiration, GSR and pulse signals.
- **With an Arduino:** flash `firmware/polymac_firmware_v0`, plug the board in, pick its port (`usbmodem…` / `usbserial…`), and click **Connect**. The app reads both firmware output modes, so `PLOTTER_MODE` can stay `true` or `false`. Close the Arduino IDE's Serial Monitor/Plotter first: only one program can hold the port.

## Layout

| File | Role |
|---|---|
| `SerialPort.swift` | POSIX serial reader (115200 8N1), splits lines |
| `Reading.swift` | `Reading`, channel metadata, `SampleParser` for CSV and Serial Plotter lines |
| `SampleBuffer.swift` | Thread-safe ring buffer (60 s) the chart snapshots each frame |
| `Simulator.swift` | Fake 100 Hz signals for testing without hardware |
| `StripChart.swift` | Canvas-drawn scrolling trace with 1-second grid |
| `AppModel.swift`, `ContentView.swift` | Connection state and UI |

Tests: `swift test`.
