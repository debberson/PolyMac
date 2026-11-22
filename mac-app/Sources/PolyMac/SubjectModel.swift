import Foundation

/// Subjects, their history, and which sensors are in use.
extension AppModel {
    // MARK: - Subjects

    var history: SubjectHistory { histories[selectedProfileID] ?? SubjectHistory() }

    func history(for id: UUID) -> SubjectHistory { histories[id] ?? SubjectHistory() }

    /// The selected subject's usual resting values, from their earlier calibrations.
    var usualValues: UsualValues? { history.usual }

    /// Switching subjects mid-exam would mix two people's answers in one session.
    var subjectLocked: Bool { phase != .idle || isCalibrating || sessionInProgress || experimentRecording }

    @discardableResult
    func addProfile(named name: String) -> SubjectProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = SubjectProfile(name: trimmed.isEmpty ? "Subject \(profiles.count + 1)" : trimmed)
        profiles.append(new)
        selectedProfileID = new.id
        return new
    }

    func renameProfile(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].name = trimmed
    }

    func updateNotes(_ id: UUID, _ notes: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }), profiles[i].notes != notes else { return }
        profiles[i].notes = notes
    }

    /// Removes the subject and moves their folder (profile, calibrations, exam history) to the Trash.
    func deleteProfile(_ id: UUID) {
        guard profiles.count > 1, !(id == selectedProfileID && subjectLocked) else { return }
        do {
            try SubjectStore.trash(id, in: dataDirectory)
        } catch {
            errorMessage = "Couldn't move the subject's folder to the Trash: \(error.localizedDescription)"
            return
        }
        loadingSubjects = true
        profiles.removeAll { $0.id == id }
        loadingSubjects = false
        histories[id] = nil
        if selectedProfileID == id { selectedProfileID = profiles[0].id }
    }

    func saveProfile(_ profile: SubjectProfile) {
        do {
            try SubjectStore.save(profile, in: dataDirectory)
        } catch {
            errorMessage = "Couldn't save subject \(profile.name): \(error.localizedDescription)"
        }
    }

    func saveChangedProfiles(_ old: [SubjectProfile]) {
        for profile in profiles where old.first(where: { $0.id == profile.id }) != profile {
            saveProfile(profile)
        }
    }

    /// Loads the subject database from the data folder. A folder without one starts with the
    /// current subjects, so changing folders never leaves you with nobody to test.
    func reloadSubjects() {
        let found = SubjectStore.loadProfiles(in: dataDirectory)
        if found.isEmpty {
            profiles.forEach(saveProfile)
        } else {
            loadingSubjects = true
            profiles = found
            loadingSubjects = false
            if !profiles.contains(where: { $0.id == selectedProfileID }) { selectedProfileID = profiles[0].id }
        }
        reloadHistories()
    }

    func reloadHistories() {
        histories = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, SubjectStore.loadHistory(for: $0.id, in: dataDirectory)) })
    }

    private func saveHistory(_ id: UUID, _ update: (inout SubjectHistory) -> Void) {
        var history = history(for: id)
        update(&history)
        histories[id] = history
        do {
            try SubjectStore.save(history, for: id, in: dataDirectory)
        } catch {
            errorMessage = "Couldn't save the subject's history: \(error.localizedDescription)"
        }
    }

    // MARK: - Calibration history

    func recordCalibration(_ result: CalibrationResult) {
        let entry = CalibrationEntry(
            baseline: result.baseline,
            method: result.method,
            source: source == .simulator ? "simulator" : "serial",
            quality: Dictionary(uniqueKeysWithValues: result.quality.map { ($0.channel.title, "\($0.level): \($0.detail)") })
        )
        saveHistory(selectedProfileID) { $0.calibrations.append(entry) }
    }

    /// Calibrates without recording, from the subject's usual resting values.
    func useUsualBaseline() {
        guard let usual = usualValues, calibration == .idle || isCalibrationFinished else { return }
        let baseline = usual.baseline(sensors: enabledSensors)
        var updated = profile
        updated.baseline = baseline
        profile = updated
        recordCalibration(CalibrationResult(baseline: baseline, quality: [], method: .usual))
        calibration = .idle
        showingCalibration = false
    }

    private var isCalibrationFinished: Bool {
        if case .finished = calibration { return true }
        return false
    }

    /// How old the current baseline is, when that's long enough to matter (GSR levels in particular
    /// shift between sittings as electrodes and skin moisture change).
    var calibrationAgeWarning: String? {
        guard let baseline = profile.baseline else { return nil }
        let hours = Date.now.timeIntervalSince(baseline.recordedAt) / 3600
        guard hours > 4 else { return nil }
        return usualValues != nil
            ? "From an earlier sitting. A quick 15 s recalibration is recommended."
            : "From an earlier sitting. Recalibrate before testing."
    }

    // MARK: - Exam history

    /// Adds the finished session to the subject's exam history.
    func logExam(savedSession: String?) {
        let answered = records.filter { !$0.interrupted && $0.answer != nil }
        guard let startedAt = sessionStartedAt, !answered.isEmpty else { return }
        let overall = overallVerdict
        let entry = ExamEntry(
            id: sessionID,
            startedAt: startedAt,
            endedAt: .now,
            source: sessionSource,
            sensors: enabledSensors,
            trainingProtocol: trainingMode ? trainingProtocol : nil,
            verdict: overall?.verdict,
            verdictGauge: overall?.gauge,
            verdictSource: modelActive ? "model" : "rules",
            questions: answered.map { record in
                ExamQuestionEntry(
                    number: record.number,
                    text: record.question.text,
                    kind: record.question.kind,
                    answer: record.answer,
                    reactionIndex: record.score?.index,
                    gsrDelta: enabledSensors.contains(.gsr) ? record.score?.gsrDelta : nil,
                    heartRateDelta: enabledSensors.contains(.pulse) ? record.score?.heartRateDelta : nil,
                    breathingSuppression: enabledSensors.contains(.resp) ? record.score?.breathingSuppression : nil,
                    verdict: record.verdict,
                    mlProbability: record.mlProbability,
                    label: record.label,
                    stableAtAsk: record.stabilityAtAsk == .stable
                )
            },
            savedSession: savedSession
        )
        saveHistory(selectedProfileID) { $0.exams.append(entry) }
    }

    func deleteExam(_ examID: UUID, for subjectID: UUID) {
        saveHistory(subjectID) { $0.exams.removeAll { $0.id == examID } }
    }

    // MARK: - Sensors

    /// Sensors can't change mid-session or mid-recording: the results would mix different setups.
    var sensorsLocked: Bool { modeLocked }

    func setSensor(_ channel: Channel, on: Bool) {
        guard !sensorsLocked else { return }
        var updated = enabledSensors
        if on { updated.insert(channel) } else { updated.remove(channel) }
        guard !updated.isEmpty else { return }  // keep at least one
        enabledSensors = updated
    }

    var shownChannels: [Channel] { Channel.displayOrder.filter(enabledSensors.contains) }
}
