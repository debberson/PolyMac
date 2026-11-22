# mac-app

Native SwiftUI macOS app: reads the Arduino's serial stream and draws respiration, GSR and pulse as a live scrolling strip chart. It has two modes, switched in the toolbar:

- **Exam:** polygraph-style questioning with stability checks, calibration, a subject window and a verdict gauge.
- **Experiment** *(new)*: record physiology experiments with phases and markers, then review, annotate and interpret them.

Both show **heart rate variability (HRV)** *(new)* live under the pulse trace.

## Install

Requires macOS 14 or later, on Apple Silicon or Intel.

1. Download `PolyMac-<version>.zip` from [Releases](https://github.com/debberson/PolyMac/releases/latest) and unzip it.
2. Drag **PolyMac.app** into Applications.
3. The first launch is blocked because the app is signed ad-hoc rather than notarized by Apple (notarization needs a paid developer account). Open it anyway:
   - **macOS 15 and later:** try to open it once, then go to **System Settings → Privacy & Security**, scroll to *"PolyMac" was blocked*, click **Open Anyway**, and confirm.
   - **macOS 14:** right-click the app, choose **Open**, then **Open** again.
   - **Or in Terminal:** `xattr -dr com.apple.quarantine /Applications/PolyMac.app`

   After that it opens normally. The app is built from this repo's source by `scripts/build-app.sh`, so you can build it yourself instead (below).

The packaged app saves recordings to `~/Documents/PolyMac Data`. You can change the folder in the **Recording & Training** panel.

## Run from source

Requires macOS 14+ and Xcode (or the Swift toolchain).

```sh
cd mac-app
swift run
```

Or open `mac-app/Package.swift` in Xcode and press Run. Run this way, the app saves to the repo's `data/` folder (gitignored).

- **No hardware?** Click **Simulate** to stream generated respiration, GSR and pulse signals.
- **With an Arduino:** flash `firmware/polymac_firmware_v0`, plug the board in, pick its port (`usbmodem…` / `usbserial…`), and click **Connect**. The app reads both firmware output modes, so `PLOTTER_MODE` can stay `true` or `false`. Close the Arduino IDE's Serial Monitor/Plotter first: only one program can hold the port.

### Sensors

Not every sensor connected yet? Open **Sensors** in the toolbar and switch off the ones you don't have, for example **Breathing (resp)** before the chest band is set up. A sensor that's off is:

- hidden from the charts and the review timeline,
- skipped by the stability checks and calibration (calibration keeps the subject's earlier values for it),
- left out of the reaction score, with the remaining weights scaled up (skin 62.5% and heart 37.5% without breathing),
- given neutral "no change" values in the training features, and recorded in each session's and experiment's files.

Sensors can't be changed during a session, a recording or a calibration, so results never mix setups.

### Chart scale

**Auto Scale** in the toolbar controls the charts' vertical scale.

- **On** (default): each chart follows its signal, calmly. It widens as soon as the trace would go off the edge, only narrows once the trace has shrunk to well under half the height, and glides to the new scale rather than jumping.
- **Off**: every scale is held still, so any change you see in a trace is a real change in the signal, which makes it easier to compare before and after a question or marker. Each chart then shows **Fit** (rescale once to what's on screen) and zoom out/in buttons, plus an *off scale* warning if the signal leaves the held range. In experiment reviews, turning it off gives each lane one fixed scale for the whole recording, so scrolling and zooming don't rescale.

## Subjects

Everyone you test has a record in the **subject database**. Open it with **Subject → ⋯ → Subject Database…** (⇧⌘D), or click the history line under the subject's name.

- **Name subjects** when you add them (**⋯ → New Subject…**) and rename them any time. Each has a notes field for anything worth remembering ("had coffee", "left-handed").
- **Exams:** every session you end is added to that subject's history: date, each question with its type, answer, reaction score (hover for the skin/heart/breathing breakdown) and verdict, the overall verdict, and which sensors were on. Training labels are shown too. Discarded sessions aren't kept.
- **Calibrations:** every saved calibration is kept, with resting heart rate, HRV, breathing, GSR level and noise.
- **Usual at rest:** the median of a subject's recent calibrations. It makes calibrating a returning subject easier:
  - **Quick (15 s):** a short recording measures today's levels, and the variability estimates a short recording gets wrong lean on their history.
  - **Use Usual Baseline:** no recording at all. Fastest, but GSR levels shift between sittings, so a quick calibration is better.
  - After any calibration the app compares today with their usual ("Heart rate 84 bpm, usually 65. Higher than normal: they may be nervous…"). A baseline from an earlier sitting gets a reminder to recalibrate.

Subjects can't be switched mid-session. Deleting one moves their folder to the Trash, so it can be restored. The database is plain JSON in the data folder, next to the training sessions:

```
data/subjects/<id>/profile.json        name, notes, settings, current baseline
data/subjects/<id>/calibrations.json   every calibration
data/subjects/<id>/exams.json          every exam: questions, answers, reactions, verdicts
```

Subjects from earlier versions are moved into the database automatically. If you point the app at a different data folder that has no subjects yet, your current subjects are copied into it.

## Running an exam

1. **Subject → Calibrate…**: record a 20–60 s resting baseline for the person. It's saved per subject, along with their GSR polarity, verdict sensitivity and reaction window.
2. **Stability**: wait for *Stable*. The panel lists only the checks that need attention (signal, sensors, movement, heart rate, breathing, skin response). By default, Ask stays disabled until the subject is stable.
3. **Question**: read the selected question aloud and press **Ask** (⌘↩). Record the answer with **Yes/No** (Y/N keys), or let the subject answer in the **Subject Window**, which shows only the question and two big buttons. If nobody answers within 10 s, the question is logged as "No answer."
4. The app records the reaction for the chosen window after the answer. Ask, answer and the reaction window appear as markers on the charts, with a live reaction score.
5. **Verdict**: each relevant question is scored against the subject's control questions, or against their baseline if no controls have been asked. The gauge shows the live reading during a relevant question, and the session result otherwise.
6. **Why**: the exact changes behind each score are highlighted on the charts, live during the reaction window and afterwards:
   - **Skin:** a band from where the rise started to its peak, with a dashed line at the pre-question level and a bracket showing the size of the rise.
   - **Heart:** the two fastest beats after the question (their rate is the "peak" heart rate).
   - **Breathing:** the stretch whose depth was compared with the baseline.

   Each label says how many points that change added (for example *Q3 skin +52 · 50 of 57 pts*), and stronger bands mean a bigger share. Relevant questions are coloured by their verdict (red deceptive, yellow unclear, green truthful), control questions orange and irrelevant ones grey. A relevant question can react strongly and still read truthful when the subject's control questions reacted even more, which is how the comparison-question technique works.

Ask irrelevant, control and relevant questions in turn: control questions are the yardstick a "deceptive" reaction has to beat. The reaction score weights skin conductance rise 50%, heart rate rise 30% and breathing suppression 20% (rescaled over the sensors that are on). **It measures arousal, not honesty.**

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
| `SubjectStore.swift`, `SubjectModel.swift` | Subject database: profiles, calibration and exam history, usual resting values, sensor switches |
| `SubjectsWindow.swift` | The Subject Database window |
| `ChartScale.swift` | Vertical scale per chart: calm auto-scaling, or held with Fit and zoom |
| `Sidebar.swift`, `ExperimentSidebar.swift`, `ReviewView.swift`, `VerdictGauge.swift`, `CalibrationSheet.swift`, `SessionEndSheet.swift`, `SubjectView.swift`, `ContentView.swift` | UI |

## Building the app

```sh
mac-app/scripts/build-app.sh            # universal PolyMac.app + PolyMac-<version>.zip in mac-app/dist/
mac-app/scripts/build-app.sh --native   # this Mac's architecture only, faster
mac-app/scripts/build-app.sh --install  # also copy it to /Applications
```

The version number comes from [`VERSION`](VERSION). For a release, bump it, run the script, and attach `dist/PolyMac-<version>.zip` to a GitHub release. The script builds in a temporary folder (iCloud-synced folders break code signing), signs ad-hoc, and checks the signature. With an Apple Developer ID it can sign and notarize instead; see the comments at the top of the script. The icon is drawn by `scripts/make-icon.swift` and committed as `Resources/AppIcon.icns`.

## Tests

`swift test`. If the repo is in an iCloud-synced folder (like `~/Documents`) and the test build fails with "resource fork, Finder information, or similar detritus not allowed", build outside it: `swift test --scratch-path /tmp/polymac-build`.
