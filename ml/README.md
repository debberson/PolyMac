# ml: training PolyMac's model

The Mac app records labeled sessions into `data/` (gitignored). `train.py` learns from them and writes a Core ML model back into `data/models/`, which the app loads.

```
Mac app ──(training sessions)──▶ data/sessions/<subject>/*/questions.csv
                                          │
                                   ml/train.sh
                                          ▼
Mac app ◀──(Reload)── data/models/PolyMacModel.mlmodel + model_info.json
```

## One-time setup

```sh
ml/setup.sh
```

This creates a Python 3.11 environment with scikit-learn, pandas and coremltools in `~/.polymac/ml-venv`. It's kept out of the repo because iCloud Drive offloads files in `~/Documents`, and Python then stalls for minutes downloading its own packages. Set `POLYMAC_VENV` to put it elsewhere. If you have an old `ml/.venv`, you can delete it.

## Collecting training data

In the app's **Recording & Training** panel:

1. Turn on **Record sessions** and **Training session (labeled data)**.
2. Pick a protocol:
   - **Card test** (recommended): the subject secretly picks a number and writes it down. Ask every generated question ("Is your number 4?"); they answer No to all of them. At the end, enter the number they picked and every answer is labeled automatically. One lie per round, two rounds.
   - **Label afterwards**: use your own questions where you know the truth (for example, the subject follows a sealed note saying which questions to lie on), then mark each answer Truth / Lie when you end the session.
3. Calibrate the subject, wait for **Stable**, and run the session.
4. Click **End & Label**, check the labels, and click **Save Session**.

Each session is saved to `data/sessions/<subject name>/<date>_<id>/`, one folder per subject (sessions saved before this grouping are moved into their subject's folder the next time the app opens):

| File | Contents |
|---|---|
| `session.json` | Subject ID, protocol, picked card, baseline, settings, whether it was simulated |
| `questions.csv` | One row per question: text, answer, `label` (truth/lie/unknown), the rule-based `rule_index`, and every `f_*` feature |
| `signals.csv` | Raw 100 Hz samples for the whole session (for re-extracting features later) |

Inside the files, subjects are identified only by an anonymous ID; `data/subjects.json` maps the IDs back to names, locally only. The folder names do show subject names, so rename the folders (or copy just the CSVs) before sharing sessions with anyone.

**How much data:** results mean little below about 10 subjects. Aim for 20–30+ people and a few hundred labeled answers. A card test gives 12 answers per session, 2 of them lies; running it two or three times per person helps.

## Every time you want to train

```sh
ml/train.sh
```

Then in the app: **Recording & Training → Reload**, and turn on **Use trained model for verdicts**.

What the script does:

1. Loads every labeled answer from `data/sessions/`. It skips simulator sessions, unlabeled ("?") answers, and sessions recorded with an older feature version.
2. Evaluates logistic regression, random forest and gradient boosting with **leave-one-subject-out** testing: every score comes from people the model never saw, which is the honest measure of how it does on someone new.
3. Prints each model's **AUC** (0.5 = coin flip, 1.0 = perfect) next to the app's current **rule-based** score, plus the most influential features.
4. Retrains the best model on all data, archives the previous model under `data/models/archive/`, and saves the new one.

The app's panel says whether the model beats the rule-based score. Only switch to it when it does.

Options:

```sh
ml/train.sh --dry-run             # evaluate only, don't replace the model
ml/train.sh --include-simulated   # include simulator sessions (pipeline testing only)
ml/train.sh --data /other/folder  # train from a specific data folder
```

`ml/train.sh` finds your sessions on its own: the downloaded app saves to `~/Documents/PolyMac Data`, and `swift run` saves to the repo's `data/`. It uses whichever has sessions (the most recently recorded one if both do) and prints which. The new model is written to that folder's `models/`, which is where the app looks for it, so click **Reload** in the app afterwards.

## Adding or changing features

Features are computed in `mac-app/Sources/PolyMac/Features.swift` (`Signal.features`). The app uses that same code to export training data and to feed the live model, so the two never drift apart. When you change a feature, bump `Signal.featureVersion`: training then uses only sessions recorded with the newest version. Raw `signals.csv` is kept, so older sessions can be re-processed later if needed.

## Testing the pipeline without hardware

```sh
cd mac-app
POLYMAC_DEMO_DATA=/tmp/polymac-demo swift test --scratch-path /tmp/polymac-build --filter writeDemoTrainingData
cd ..
ml/train.sh --data /tmp/polymac-demo --include-simulated
```

This writes 32 synthetic card-test sessions through the app's real feature and export code, then trains on them. The scores come out near-perfect because the synthetic lies are easy to spot. That only proves the plumbing works.

## Keep in mind

The model learns whatever separates your labels in your sessions: staged lies, told by people you know, on this hardware. It can get better at that, but it measures arousal, not honesty, and it isn't a validated lie detector.
