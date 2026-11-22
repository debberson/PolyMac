# mac-app

Native SwiftUI macOS app: reads the Arduino's serial stream and draws respiration, GSR and pulse as a live scrolling strip chart. It has two modes, switched in the toolbar:

- **Exam:** polygraph-style questioning with stability checks, calibration, a subject window and a verdict gauge.
- **Experiment** *(new)*: record physiology experiments with phases and markers, then review, annotate and interpret them.

Both show **heart rate variability (HRV)** *(new)* live under the pulse trace.

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

## Experiment mode

Switch the toolbar to **Experiment**. The sidebar swaps the exam panels for experiment controls.

### Recording

1. Calibrate the subject and wait for **Stable** (same panels as in Exam mode).
2. Pick a **template** and optionally give the recording a title:

   | Template | Phases | What to look for |
   |---|---|---|
   | Free recording | You start phases yourself (Rest / Task / Recovery / any name) | Anything you like |
   | Paced breathing | Rest 2:00 → Paced breathing 3:00 → Recovery 2:00 | Bigger heart-rate swings with each breath, higher HRV |
   | Mental arithmetic | Rest 2:00 → Task 2:00 → Recovery 2:00 | Heart rate and skin responses up, HRV down, then recovery |
   | Exercise recovery | Rest 1:00 → Exercise 1:00 → Recovery 3:00 | Heart-rate drop in the first minute of recovery |
   | Habituation | Rest 1:00 → Stimuli 4:00 → Recovery 1:00 | Skin responses to a repeated sound shrinking |

3. Click **Start Recording**. Templates advance through their phases on a timer (or click **Skip to Next Phase**). Phases are shaded on the live charts.
4. **Markers:** type an optional label and press **Add Marker** (⌘↩) whenever something happens: a sound, a question, someone walking in. Markers appear on the live charts.
5. Click **Stop & Review**. A template stops by itself after its last phase. If the data stream stops, the recording is finished and saved too.

### Reviewing and interpreting

After recording, the Review screen shows the whole recording:

- **Timeline:** all three channels with phases and markers. Zoom from 10 s to the whole recording and scroll with the slider.
- **Markers after recording:** **double-click** a trace to add a marker at that moment. Rename or delete markers in the sidebar, and click a marker's time to jump to it.
- **Interpretation:** each phase compared with the rest phase in plain language (for example, "Task vs Rest: heart rate +12 bpm, HRV −38%, 3.2 vs 0.4 skin responses/min… points to heightened arousal"), heart-rate recovery after exercise, and habituation across markers.
- **Phases table:** heart rate, HRV, breathing rate and skin responses per minute for each phase.
- **Marker responses:** skin-conductance rise and heart-rate change in the 10 s after each marker.
- **Notes:** free text saved with the recording.

Every recording is saved automatically to `data/experiments/<date>_<title>/` and listed under **Saved Experiments**, where you can reopen it any time. Edits (markers, title, notes) are saved as you make them.

| File | Contents |
|---|---|
| `experiment.json` | Title, template, subject, phases, markers, notes |
| `signals.csv` | Raw 100 Hz samples |
| `phases.csv` | Statistics per phase |
| `markers.csv` | Each marker's time, label and response |
| `beats.csv` | Every clean beat-to-beat interval, for HRV tools like Kubios |
| `summary.txt` | The interpretation and tables as plain text |

In simulator mode the fake subject follows the phases (stressed during Task and Exercise, slow breathing during Paced breathing) and startles at markers, less each time, so every template can be tried without hardware.

## Heart rate variability (HRV)

HRV is the variation in time between heartbeats. PolyMac finds each beat's peak in the pulse signal, refines its timing between samples, drops artifacts (missed or extra beats), and reports:

- **RMSSD:** beat-to-beat variation, driven mostly by the vagus nerve ("rest and digest"). Higher when relaxed, lower under stress or effort. Shown live (last 30 s) under the pulse trace.
- **SDNN:** overall variation, including slower swings.

Both are reported per phase in experiment reviews. A fingertip pulse sensor gives estimates, not clinical values: compare phases of similar length within one person rather than reading absolute numbers.

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
| `Experiment.swift`, `ExperimentModel.swift` | Experiment templates, phases, markers, live recording and review state |
| `ExperimentAnalysis.swift` | HRV, per-phase statistics, marker responses, interpretation |
| `ExperimentFiles.swift` | Saving and reopening `data/experiments/` |
| `Simulator.swift` | Fake 100 Hz signals that react to questions, stress and breathing pace |
| `StripChart.swift` | Canvas-drawn scrolling trace with question markers and live stats |
| `Sidebar.swift`, `ExperimentSidebar.swift`, `ReviewView.swift`, `VerdictGauge.swift`, `CalibrationSheet.swift`, `SessionEndSheet.swift`, `SubjectView.swift`, `ContentView.swift` | UI |

Tests: `swift test`. If the repo is in an iCloud-synced folder (like `~/Documents`) and the test build fails with "resource fork, Finder information, or similar detritus not allowed", build outside it: `swift test --scratch-path /tmp/polymac-build`.
