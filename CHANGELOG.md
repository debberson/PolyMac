# Changelog

## 1.0.0

First downloadable release: a universal app for Apple Silicon and Intel Macs, macOS 14 or later.

**Exams**
- Calibration, stability checks, irrelevant / control / relevant questions, an optional subject-facing window, a live reaction score and a verdict gauge.
- The changes behind each score are highlighted on the charts (skin rise, fastest heartbeats, breathing stretch), labeled with the points each added.
- Slow skin drift is allowed for in scoring, so sweat building up under the electrodes isn't counted as a reaction.
- Verdict sensitivity per subject, from cautious to decisive.

**Subjects**
- A subject database: every exam with its questions, answers, reactions and verdicts, and every calibration.
- Each subject's usual resting heart rate, HRV and GSR level, for a 15-second recalibration or none at all, and a comparison with today's values.
- Saved sessions and saved question lists are filed in one folder per subject.

**Questions**
- Save, clear, and reload question lists; each save records who the questions were asked to, when, and how they were answered.

**Signals**
- Turn sensors on or off to match what's connected; sensors that are off are left out of every check and score.
- Calibration warns when the skin electrodes are still settling or the sensor is near its limit.
- Mains hum is filtered off the skin and breathing traces.
- Calm auto-scaling, or held scales with Fit and zoom.
- Heart rate variability (RMSSD, SDNN), live and per phase.

**Experiments**
- Templates (paced breathing, mental arithmetic, exercise recovery, habituation) or free recording, live markers, then review: edit markers on a zoomable timeline, compare phases, and read a plain-language interpretation.

**Data**
- Sessions saved as labeled training data, and a Core ML training pipeline in `ml/`.
- A built-in simulator to try everything without hardware.
