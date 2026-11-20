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

## Running an exam

1. **Subject → Calibrate…**: record a 20–60 s resting baseline for the person. It's saved per subject, along with their GSR polarity, verdict sensitivity and reaction window.
2. **Stability**: wait for *Stable*. The panel lists only the checks that need attention (signal, sensors, movement, heart rate, breathing, skin response). By default, Ask stays disabled until the subject is stable.
3. **Question**: read the selected question aloud and press **Ask** (⌘↩). Record the answer with **Yes/No** (Y/N keys), or let the subject answer in the **Subject Window**, which shows only the question and two big buttons. If nobody answers within 10 s, the question is logged as "No answer."
4. The app records the reaction for the chosen window after the answer. Ask, answer and the reaction window appear as markers on the charts, with a live reaction score.
5. **Verdict**: each relevant question is scored against the subject's control questions, or against their baseline if no controls have been asked. The gauge shows the live reading during a relevant question, and the session result otherwise.

Ask irrelevant, control and relevant questions in turn: control questions are the yardstick a "deceptive" reaction has to beat. The reaction score weights skin conductance rise 50%, heart rate rise 30% and breathing suppression 20%. **It measures arousal, not honesty.**

## Recording and training data

The **Recording & Training** panel saves each session to `data/sessions/` (gitignored) when you click **End & Save**: questions, answers, results, per-question features and raw signals. Turn on **Training session** for structured, labeled sessions (a card test or labeling afterwards) that can train a model. See [`../ml/README.md`](../ml/README.md) for collecting data and training.

In simulator mode, the **Simulated subject** picker sets whether the fake subject reacts strongly to relevant questions (Lying), weakly (Honest), or at random.

## Layout

| File | Role |
|---|---|
| `SerialPort.swift` | POSIX serial reader (115200 8N1), splits lines |
| `Reading.swift` | `Reading`, channel metadata, `SampleParser` for CSV and Serial Plotter lines |
| `SampleBuffer.swift` | Thread-safe 5-minute ring buffer, addressed by absolute sample index |
| `SignalAnalysis.swift` | Heart/breathing rate, skin responses, stability checks, calibration, reaction scoring, verdict |
| `Exam.swift` | Questions, answers, records, subject profiles, persistence |
| `Features.swift` | Per-question features shared by the training export and the live model |
| `Recording.swift` | Training protocols, labels, session export to `data/` |
| `DeceptionModel.swift` | Loads the Core ML model from `ml/train.py` |
| `AppModel.swift` | Connection, 5 Hz analysis loop, calibration and question state machines |
| `Simulator.swift` | Fake 100 Hz signals that react to questions |
| `StripChart.swift` | Canvas-drawn scrolling trace with question markers and live stats |
| `Sidebar.swift`, `VerdictGauge.swift`, `CalibrationSheet.swift`, `SessionEndSheet.swift`, `SubjectView.swift`, `ContentView.swift` | UI |

Tests: `swift test`. If the repo is in an iCloud-synced folder (like `~/Documents`) and the test build fails with "resource fork, Finder information, or similar detritus not allowed", build outside it: `swift test --scratch-path /tmp/polymac-build`.
