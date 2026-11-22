import Foundation

/// Experiment mode: record with phases and markers, then review, annotate and interpret.
extension AppModel {
    var experimentTemplate: ExperimentTemplate { .find(experimentTemplateID) }

    /// Samples since the live recording began.
    var experimentPosition: Int { experimentRecording ? currentSample - experimentStart : 0 }
    var experimentElapsed: Double { Double(experimentPosition) / Signal.sampleRate }

    var currentExperimentPhase: ExperimentPhase? { experimentRecording ? experimentPhases.last : nil }

    /// Seconds left in the current timed phase (templates only).
    var phaseSecondsLeft: Double? {
        guard experimentRecording, let index = experimentPhases.indices.last, index < experimentTemplate.phases.count else { return nil }
        let planned = Double(experimentTemplate.phases[index].seconds)
        return max(0, planned - Double(experimentPosition - experimentPhases[index].start) / Signal.sampleRate)
    }

    var phaseProgress: Double {
        guard let left = phaseSecondsLeft, let index = experimentPhases.indices.last else { return 0 }
        let planned = Double(experimentTemplate.phases[index].seconds)
        return planned > 0 ? 1 - left / planned : 0
    }

    var experimentBlockedReason: String? {
        if !isRunning { return "Connect a board or start the simulator." }
        if isCalibrating { return "Wait for calibration to finish." }
        if sessionInProgress { return "End the current exam session first." }
        return nil
    }

    var modeLocked: Bool { experimentRecording || sessionInProgress || isCalibrating }

    // MARK: Live recording

    func startExperiment() {
        guard experimentBlockedReason == nil, !experimentRecording else { return }
        experimentStart = buffer.totalCount
        experimentNext = experimentStart
        experimentChannels = [[], [], []]
        experimentMarkers = []
        experimentPhases = []
        markerDraft = ""
        if experimentTitle.trimmingCharacters(in: .whitespaces).isEmpty { experimentTitle = experimentTemplate.title }
        experimentRecording = true
        if let first = experimentTemplate.phases.first { beginPhase(first) }
    }

    /// Ends the current phase and starts a named one (free recordings).
    func beginPhase(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard experimentRecording, !trimmed.isEmpty else { return }
        let lower = trimmed.lowercased()
        let stress = lower.contains("exercise") ? 1 : lower.contains("task") || lower.contains("stress") ? 0.7 : lower.contains("recover") ? 0.1 : 0
        beginPhase(PhasePlan(name: trimmed, seconds: 0, simulatedStress: stress, simulatedBreathing: lower.contains("breath") ? 6 : 15))
    }

    private func beginPhase(_ plan: PhasePlan) {
        captureExperimentSignals()
        let now = experimentPosition
        if let last = experimentPhases.indices.last { experimentPhases[last].end = now }
        experimentPhases.append(ExperimentPhase(name: plan.name, start: now, end: now))
        simulator?.setStress(plan.simulatedStress)
        simulator?.setBreathingRate(plan.simulatedBreathing)
    }

    /// Templates: move to the next timed phase, or finish after the last one.
    func nextPhase() {
        guard experimentRecording else { return }
        let next = experimentPhases.count
        if next < experimentTemplate.phases.count {
            beginPhase(experimentTemplate.phases[next])
        } else {
            finishExperiment()
        }
    }

    func addMarker() {
        guard experimentRecording else { return }
        let label = markerDraft.trimmingCharacters(in: .whitespaces)
        experimentMarkers.append(ExperimentMarker(
            sample: experimentPosition,
            label: label.isEmpty ? "Marker \(experimentMarkers.count + 1)" : label,
            addedLive: true
        ))
        markerDraft = ""
        // The fake subject startles at events, less each time (so habituation shows up in demos).
        simulator?.stimulate(strength: 0.9 * pow(0.78, Double(experimentMarkers.count - 1)))
    }

    func finishExperiment() {
        guard experimentRecording else { return }
        captureExperimentSignals()
        let length = experimentChannels[0].count
        if let last = experimentPhases.indices.last { experimentPhases[last].end = length }
        experimentRecording = false
        simulator?.setStress(0)
        simulator?.setBreathingRate(15)

        let recording = ExperimentRecording(
            title: experimentTitle.trimmingCharacters(in: .whitespaces).isEmpty ? experimentTemplate.title : experimentTitle,
            templateID: experimentTemplateID,
            subjectID: profile.id,
            subjectName: profile.name,
            startedAt: Date.now.addingTimeInterval(-Double(length) / Signal.sampleRate),
            source: source == .simulator ? "simulator" : "serial",
            gsrInverted: profile.gsrInverted,
            baseline: profile.baseline,
            channels: experimentChannels,
            markers: experimentMarkers,
            phases: experimentPhases.filter { $0.end > $0.start }
        )
        experimentChannels = [[], [], []]
        experimentTitle = ""
        openReview(recording, save: true)
    }

    func advanceExperiment() {
        guard experimentRecording else { return }
        captureExperimentSignals()
        let now = experimentPosition
        guard let last = experimentPhases.indices.last else { return }
        experimentPhases[last].end = now
        if last < experimentTemplate.phases.count,
           now - experimentPhases[last].start >= Signal.samples(Double(experimentTemplate.phases[last].seconds)) {
            nextPhase()
        }
    }

    /// Copies newly arrived samples into the recording, keeping indices aligned with the start.
    private func captureExperimentSignals() {
        guard experimentRecording else { return }
        let end = buffer.totalCount
        let (first, chunk) = buffer.range(from: experimentNext, to: end)
        experimentNext = end
        guard !chunk[0].isEmpty else { return }
        // A gap (samples lost from the buffer) is filled with the last value so marker times stay right.
        let gap = first - (experimentStart + experimentChannels[0].count)
        if gap > 0 {
            for channel in 0..<3 {
                let fill = experimentChannels[channel].last ?? chunk[channel][0]
                experimentChannels[channel] += Array(repeating: fill, count: gap)
            }
        }
        for channel in 0..<3 { experimentChannels[channel] += chunk[channel] }
    }

    // MARK: Review

    func openReview(_ recording: ExperimentRecording, save: Bool) {
        review = recording
        reviewAnalysis = Signal.analyze(recording)
        reviewWindowStart = 0
        reviewZoom = recording.duration > 90 ? 60 : 0
        reviewSaveStatus = nil
        appMode = .experiment
        if save { saveReview(includeSignals: true) }
    }

    func closeReview() {
        review = nil
        reviewAnalysis = nil
    }

    func addReviewMarker(at sample: Int) {
        guard var recording = review, (0..<recording.sampleCount).contains(sample) else { return }
        recording.markers.append(ExperimentMarker(sample: sample, label: "Marker \(recording.markers.count + 1)", addedLive: false))
        recording.markers.sort { $0.sample < $1.sample }
        updateReview(recording)
    }

    func renameMarker(_ id: UUID, to label: String) {
        guard var recording = review, let i = recording.markers.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        recording.markers[i].label = trimmed.isEmpty ? "Marker \(i + 1)" : trimmed
        updateReview(recording)
    }

    func deleteMarker(_ id: UUID) {
        guard var recording = review else { return }
        recording.markers.removeAll { $0.id == id }
        updateReview(recording)
    }

    func renamePhase(_ id: UUID, to name: String) {
        guard var recording = review, let i = recording.phases.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        recording.phases[i].name = trimmed
        updateReview(recording)
    }

    /// Title and notes: saved without re-running the analysis.
    func updateReviewText(title: String? = nil, notes: String? = nil) {
        guard var recording = review else { return }
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { recording.title = title }
        if let notes { recording.notes = notes }
        review = recording
        saveReview()
    }

    func jumpReview(toSample sample: Int) {
        guard let recording = review, reviewZoom > 0 else { return }
        let center = Double(sample) / Signal.sampleRate
        reviewWindowStart = min(max(0, center - reviewZoom / 2), max(0, recording.duration - reviewZoom))
    }

    private func updateReview(_ recording: ExperimentRecording) {
        review = recording
        reviewAnalysis = Signal.analyze(recording)
        saveReview()
    }

    func saveReview(includeSignals: Bool = false) {
        guard var recording = review else { return }
        let analysis = reviewAnalysis ?? Signal.analyze(recording)
        do {
            let folder = try ExperimentFiles.write(recording, analysis: analysis, includeSignals: includeSignals, to: dataDirectory)
            if recording.folder == nil {
                recording.folder = folder
                review = recording
                refreshSavedExperiments()
            }
            reviewSaveStatus = "Saved to experiments/\(folder.lastPathComponent)"
        } catch {
            reviewSaveStatus = "Couldn't save: \(error.localizedDescription)"
        }
    }

    func refreshSavedExperiments() {
        savedExperiments = ExperimentFiles.list(in: dataDirectory)
    }

    func openSavedExperiment(_ saved: SavedExperiment) {
        do {
            let recording = try ExperimentFiles.load(saved.folder, subjectNames: ExperimentFiles.subjectNames(in: dataDirectory))
            openReview(recording, save: false)
            reviewSaveStatus = "Opened experiments/\(saved.folder.lastPathComponent)"
        } catch {
            errorMessage = "Couldn't open \(saved.title): \(error.localizedDescription)"
        }
    }
}
