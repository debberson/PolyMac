# PolyMac

Open-source, Mac-native polygraph and kymograph software. Streams live respiration, galvanic skin response (GSR), and pulse data from Arduino-connected sensors into a real-time SwiftUI strip-chart recorder — built because no open-source polygraph software exists for Apple devices.

> **Status:** 🚧 early work in progress. Hardware is still being sourced and no firmware/app code has been written yet. This README describes the planned shape of the project and will be updated as pieces land.

## Disclaimer

This is a recreational and educational hobby project, **not** a validated lie-detection device. Polygraph-style measurements (respiration, skin conductance, pulse) are not scientifically reliable indicators of truthfulness, and nothing in this repo should be used to make real judgments about anyone. It's built for fun, curiosity, and learning electronics/software — treat it the same way you'd treat a party game, not a forensic tool.

## How it works

```
 pneumograph ─┐
 galvanograph ─┼─▶ analog pins ─▶ Arduino ─▶ USB serial ─▶ macOS app ─▶ live scrolling chart
 cardiosphygmograph ─┘                (fixed-rate sampling,           (SwiftUI)
                                        CSV-over-serial)
```

An Arduino (or compatible microcontroller) digitizes three analog sensor channels and streams them over USB serial as timestamped samples. A native SwiftUI app on macOS reads that stream and renders it as a live, scrolling multi-channel strip chart — the classic polygraph look — with support for recording sessions and marking events (e.g. "question asked") on the timeline.

## Hardware / Bill of Materials

| Channel | Sensor | Notes |
|---|---|---|
| Cardiosphygmograph (pulse) | Pulse Sensor Amped (~$30) | Plug-and-play, 3-pin cable straight into an analog pin |
| Galvanograph (GSR) | Grove GSR Sensor (~$15–25) | Two finger electrodes, wires to 5V / GND / analog pin |
| Pneumograph (respiration) | DIY conductive stretch-sensor chest band | Wired into a voltage divider with a fixed resistor — no off-the-shelf plug-and-play part exists for this one |
| Microcontroller | Arduino Uno (or compatible) | Any board with 3+ analog inputs and USB serial works |

See [`docs/getting-started.md`](docs/getting-started.md) for the full beginner-friendly build path, including a starter-kit recommendation and reference tutorials for the DIY respiration sensor.

## Repo structure

```
/firmware   — Arduino sketches (sensor sampling + serial protocol)
/mac-app    — Xcode project (SwiftUI live chart / recorder)
/docs       — build guides, wiring diagrams, hardware notes
```

## Getting started

**Firmware**
1. Wire the three sensors to separate analog pins on the Arduino (see wiring diagram in `/docs`).
2. Open `/firmware` in the Arduino IDE, select your board, and upload.
3. Verify each channel looks sane using the Arduino IDE's Serial Plotter before moving to the Mac app.

**macOS app**
1. Open `/mac-app` in Xcode.
2. Build and run — the app will list available serial ports; select the Arduino's port to connect.
3. *(Coming soon: build/run instructions once the app exists.)*

## Roadmap

- [ ] Arduino firmware — sample all 3 channels, stream over serial
- [ ] Minimal Mac app — connect to serial port, log incoming values
- [ ] Live scrolling chart for one channel, then all three
- [ ] Session recording (CSV/JSON) + event markers
- [ ] Stretch: derived metrics (breathing rate, GSR response detection, heart rate), playback/review mode

## Contributing

Contributions, issues, and hardware-variant reports (different sensors/boards) are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Acknowledgments

- [Pulse Sensor Amped](https://www.adafruit.com/product/1093) (Adafruit)
- [Grove GSR Sensor](https://wiki.seeedstudio.com/Grove-GSR_Sensor/) (Seeed Studio)
- DIY conductive stretch-sensor respiration belt approach, per [kobakant's writeup](https://blog.adafruit.com/2020/04/28/a-breathing-sensor-belt-by-kobakant/) and the [Instructables breath-sensor guide](https://www.instructables.com/DIY-Breath-Sensor-with-Arduino-Conductive-Knitted-/)

## License

MIT — see [`LICENSE`](LICENSE).
