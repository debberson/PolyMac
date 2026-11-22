# PolyMac

an open-source, Mac-native polygraph and kymograph software. Streams live respiration, galvanic skin response (GSR), and pulse data (HR) from Arduino-connected sensors into a real-time SwiftUI strip-chart recorder. Built cuz no open-source polygraph software exists for Apple devices.

> **Status:** v1.0. The firmware and the Mac app both run and have been tested on hardware, and the app has a built-in simulator so you can try everything without hardware. [Download the app](https://github.com/debberson/PolyMac/releases/latest) or build it from source.

## What's new

- **Downloadable app (v1.0):** grab `PolyMac-1.0.0.zip` from [Releases](https://github.com/debberson/PolyMac/releases/latest), no Xcode needed. Runs natively on Apple Silicon and Intel Macs with macOS 14 or later.
- **Experiment mode:** record physiology experiments instead of interrogations. Pick a template (paced breathing, mental arithmetic, exercise recovery, habituation) or record freely, drop markers live, then **review and interpret the recording afterwards**: add or edit markers on a zoomable timeline, compare phases side by side, and get a plain-language summary. See [Experiment mode](mac-app/README.md#experiment-mode).
- **Heart rate variability (HRV):** RMSSD and SDNN from beat-to-beat intervals, shown live under the pulse trace and per phase in experiment reviews.
- **Session recording and model training:** exam sessions can be saved as labeled training data, and [`ml/`](ml/README.md) trains a Core ML model the app can use.

## Disclaimer

This is a recreational and educational hobby project, **not** a validated and lab-tested lie detection device. Polygraph-style measurements (respiration, skin conductance, pulse) are not concrete indicators of truthfulness, and nothing in this repo should be used to make real judgments about anyone. It's mainly built for fun, curiosity, and learning electronics/software. Please treat it the same way you'd treat a party game, not as a forensics tool cuz it has zero approved analytical power.

## How it works

```
 pneumograph ─┐
 galvanograph ─┼─▶ analog pins ─▶ Arduino ─▶ USB serial ─▶ macOS app ─▶ live scrolling chart
 cardiosphygmograph ─┘                (fixed-rate sampling,           (SwiftUI)
                                        CSV-over-serial)
```

An Arduino (or compatible microcontroller) digitizes three analog sensor channels and streams them over USB serial as timestamped samples. A native SwiftUI app on macOS reads that stream and renders it as a live, scrolling multi-channel strip chart — the classic polygraph look — with support for recording sessions and marking events (e.g. "question asked") on the timeline.

The app has two modes:

- **Exam:** the polygraph workflow. Calibrate a subject, check they're stable, ask irrelevant/control/relevant questions (with an optional subject-facing window), and watch a live reaction score and a "verdict" gauge. It's a party game; see the disclaimer.
- **Experiment:** a small physiology lab. Record phases (rest, task, recovery…) and markers, then review the recording with per-phase heart rate, HRV, breathing and skin-response statistics, each marker's response, and an automatic interpretation.

## Hardware

| Channel | Sensor | Notes | Link |
|---|---|---|--|
| Cardiosphygmograph (pulse) | Pulse Sensor Amped (~$30) | Plug-and-play, 3-pin cable straight into an analog pin | https://www.adafruit.com/product/1093 |
| Galvanograph (GSR) | Grove GSR Sensor (~$15–25) | Two finger electrodes, wires to 5V / GND / analog pin | https://www.digikey.ca/en/products/detail/seeed-technology-co-ltd/101020052/5488086?so=101609145&content=productdetail_CA&mkt_tok=MDI4LVNYSy01MDcAAAGkQIGuY2miQXMb3nVGh1h0eAkpksHjhG5TxFPNO-uFGeladAvEHE0xR8qAw5I1nK7bP6JqOfMOuirIhRZaY4w4KpbXGin-rdcTQ4AD3-AJEag |
| Pneumograph (respiration) | DIY conductive stretch-sensor chest band | Wired into a voltage divider with a fixed resistor — no off-the-shelf plug-and-play part exists for this one | https://www.adafruit.com/product/519 |
| Microcontroller | Arduino Uno (or compatible) | Any board with 3+ analog inputs and USB serial works | https://www.amazon.ca/ELEGOO-Project-Complete-Starter-Tutorial/dp/B01M9CHF1J |

See [`docs/getting-started.md`](docs/getting-started.md) for the full beginner-friendly build path, including a starter-kit recommendation and reference tutorials for the DIY respiration sensor.

## Repo structure

```
/firmware   — Arduino sketches (sensor sampling + serial protocol)
/mac-app    — SwiftUI app (Swift package): live charts, exam and experiment modes
/ml         — model training from recorded sessions (Python → Core ML)
/docs       — build guides, wiring diagrams, hardware notes
/data       — your recordings and trained models (created by the app, gitignored)
```

## Getting started

**Firmware**
1. Wire the three sensors to separate analog pins on the Arduino (see wiring diagram in `/docs`).
2. Open `/firmware` in the Arduino IDE, select your board, and upload.
3. Verify each channel looks sane using the Arduino IDE's Serial Plotter before moving to the Mac app.

**macOS app** (macOS 14+, Apple Silicon or Intel)
1. Download `PolyMac-<version>.zip` from [Releases](https://github.com/debberson/PolyMac/releases/latest), unzip it, and drag **PolyMac** to Applications. The app isn't notarized by Apple, so the first launch is blocked: open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** (details in [`mac-app/README.md`](mac-app/README.md#install)).
   *From source instead:* `cd mac-app && swift run` (needs Xcode), or build your own `.app` with `mac-app/scripts/build-app.sh`.
2. No hardware yet? Click **Simulate**. Otherwise pick the Arduino's port and click **Connect**.
3. Switch between **Exam** and **Experiment** in the toolbar. Full guide: [`mac-app/README.md`](mac-app/README.md).

## Roadmap

- [x] Arduino firmware — sample all 3 channels, stream over serial
- [x] Minimal Mac app — connect to serial port, log incoming values
- [x] Live scrolling chart for one channel, then all three
- [x] Session recording (CSV/JSON) + event markers
- [x] Derived metrics (breathing rate, GSR response detection, heart rate, HRV), playback/review mode
- [x] Experiment mode with phases, live and after-the-fact markers, and interpretation
- [x] Test on real hardware
- [x] Downloadable, universal `.app` (v1.0)
- [ ] Tune thresholds across more people and sensors
- [ ] Notarized builds (needs an Apple Developer account)
- [ ] Wiring diagrams in `/docs`

## Contributing

Contributions, issues, and hardware-variant reports (different sensors/boards) are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Acknowledgments

- [Pulse Sensor Amped](https://www.adafruit.com/product/1093) (Adafruit)
- [Grove GSR Sensor](https://wiki.seeedstudio.com/Grove-GSR_Sensor/) (Seeed Studio)
- DIY conductive stretch-sensor respiration belt approach, per [kobakant's writeup](https://blog.adafruit.com/2020/04/28/a-breathing-sensor-belt-by-kobakant/) and the [Instructables breath-sensor guide](https://www.instructables.com/DIY-Breath-Sensor-with-Arduino-Conductive-Knitted-/)

## License

MIT — see [`LICENSE`](LICENSE).
