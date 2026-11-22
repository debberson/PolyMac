import Foundation

/// Reads and writes `<data>/experiments/<date>_<title>/`:
/// - `experiment.json`: title, template, subject, phases, markers, notes
/// - `signals.csv`: raw 100 Hz samples (`sample,time_s,resp,pulse,gsr`)
/// - `phases.csv`: statistics per phase
/// - `markers.csv`: each marker's time, label and the body's response
/// - `beats.csv`: every clean beat-to-beat interval (for HRV tools like Kubios)
/// - `summary.txt`: the interpretation and tables in plain text
enum ExperimentFiles {
    static let schemaVersion = 1

    private struct Metadata: Codable {
        var schemaVersion: Int
        var id: UUID
        var title: String
        var template: String
        var subjectId: UUID
        var startedAt: Date
        var source: String
        var sampleRate: Double
        var samples: Int
        var gsrInverted: Bool
        var baseline: Baseline?
        var phases: [ExperimentPhase]
        var markers: [ExperimentMarker]
        var notes: String
    }

    /// Writes everything; `signals.csv` and `beats.csv` only when `includeSignals` (they never change after recording).
    @discardableResult
    static func write(_ recording: ExperimentRecording, analysis: ExperimentAnalysis, includeSignals: Bool, to dataDirectory: URL) throws -> URL {
        let folder = recording.folder ?? newFolder(for: recording, in: dataDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let metadata = Metadata(
            schemaVersion: schemaVersion, id: recording.id, title: recording.title, template: recording.templateID,
            subjectId: recording.subjectID, startedAt: recording.startedAt, source: recording.source,
            sampleRate: Signal.sampleRate, samples: recording.sampleCount, gsrInverted: recording.gsrInverted,
            baseline: recording.baseline, phases: recording.phases,
            markers: recording.markers.sorted { $0.sample < $1.sample }, notes: recording.notes
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: folder.appending(path: "experiment.json"))

        if includeSignals || !FileManager.default.fileExists(atPath: folder.appending(path: "signals.csv").path) {
            try signalsCSV(recording).write(to: folder.appending(path: "signals.csv"), atomically: true, encoding: .utf8)
            try beatsCSV(recording).write(to: folder.appending(path: "beats.csv"), atomically: true, encoding: .utf8)
        }
        try phasesCSV(analysis).write(to: folder.appending(path: "phases.csv"), atomically: true, encoding: .utf8)
        try markersCSV(analysis).write(to: folder.appending(path: "markers.csv"), atomically: true, encoding: .utf8)
        try summary(recording, analysis).write(to: folder.appending(path: "summary.txt"), atomically: true, encoding: .utf8)
        try SessionExporter.updateSubjectIndex(id: recording.subjectID, name: recording.subjectName, in: dataDirectory)
        return folder
    }

    static func list(in dataDirectory: URL) -> [SavedExperiment] {
        let root = dataDirectory.appending(path: "experiments")
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let metadata = try? readMetadata(folder) else { return nil }
            return SavedExperiment(folder: folder, title: metadata.title, startedAt: metadata.startedAt, duration: Double(metadata.samples) / metadata.sampleRate)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    static func load(_ folder: URL, subjectNames: [String: String]) throws -> ExperimentRecording {
        let metadata = try readMetadata(folder)
        let text = try String(contentsOf: folder.appending(path: "signals.csv"), encoding: .utf8)
        var channels: [[Double]] = [[], [], []]
        for channel in channels.indices { channels[channel].reserveCapacity(metadata.samples) }
        for line in text.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: ",")
            guard fields.count >= 5, let resp = Double(fields[2]), let pulse = Double(fields[3]), let gsr = Double(fields[4]) else { continue }
            channels[0].append(resp)
            channels[1].append(pulse)
            channels[2].append(gsr)
        }
        return ExperimentRecording(
            id: metadata.id, title: metadata.title, templateID: metadata.template, subjectID: metadata.subjectId,
            subjectName: subjectNames[metadata.subjectId.uuidString] ?? "Unknown subject",
            startedAt: metadata.startedAt, source: metadata.source, gsrInverted: metadata.gsrInverted,
            baseline: metadata.baseline, channels: channels, markers: metadata.markers, phases: metadata.phases,
            notes: metadata.notes, folder: folder
        )
    }

    static func subjectNames(in dataDirectory: URL) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: dataDirectory.appending(path: "subjects.json")))) ?? [:]
    }

    private static func readMetadata(_ folder: URL) throws -> Metadata {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Metadata.self, from: Data(contentsOf: folder.appending(path: "experiment.json")))
    }

    private static func newFolder(for recording: ExperimentRecording, in dataDirectory: URL) -> URL {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let slug = recording.title.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, char in if !(char == "-" && result.last == "-") { result.append(char) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .prefix(40)
        return dataDirectory.appending(path: "experiments/\(stamp.string(from: recording.startedAt))_\(slug.isEmpty ? "experiment" : String(slug))")
    }

    // MARK: CSV and text

    private static func number(_ value: Double?, _ digits: Int = 1) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.\(digits)f", value)
    }

    private static func escape(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func signalsCSV(_ recording: ExperimentRecording) -> String {
        var out = "sample,time_s,resp,pulse,gsr\n"
        out.reserveCapacity(recording.sampleCount * 26)
        for i in 0..<recording.sampleCount {
            out += "\(i),\(String(format: "%.2f", Double(i) / Signal.sampleRate)),\(Int(recording.channels[0][i])),\(Int(recording.channels[1][i])),\(Int(recording.channels[2][i]))\n"
        }
        return out
    }

    private static func beatsCSV(_ recording: ExperimentRecording) -> String {
        let times = Signal.beatTimes(recording.channels[Channel.pulse.rawValue])
        var out = "beat_time_s,ibi_ms,heart_rate_bpm\n"
        for (time, previous) in zip(times.dropFirst(), times) {
            let interval = time - previous
            guard (0.3...1.5).contains(interval) else { continue }
            out += "\(String(format: "%.3f", time)),\(String(format: "%.1f", interval * 1000)),\(String(format: "%.1f", 60 / interval))\n"
        }
        return out
    }

    private static func phasesCSV(_ analysis: ExperimentAnalysis) -> String {
        var out = "phase,start_s,end_s,seconds,heart_rate_bpm,hrv_rmssd_ms,hrv_sdnn_ms,beats,breathing_per_min,breathing_depth,gsr_raw,gsr_arousal,skin_responses_per_min\n"
        for (phase, s) in analysis.phases {
            out += [
                escape(phase.name), number(Double(phase.start) / Signal.sampleRate, 2), number(Double(phase.end) / Signal.sampleRate, 2),
                number(s.seconds), number(s.heartRate), number(s.hrv?.rmssd), number(s.hrv?.sdnn), s.hrv.map { String($0.beats) } ?? "",
                number(s.breathingRate), number(s.breathingDepth), number(s.gsrRaw), number(s.gsrArousal), number(s.responsesPerMinute, 2),
            ].joined(separator: ",") + "\n"
        }
        return out
    }

    private static func markersCSV(_ analysis: ExperimentAnalysis) -> String {
        var out = "marker,time_s,label,added,gsr_rise,heart_rate_change_bpm,gsr_peak_latency_s\n"
        for (index, (marker, response)) in analysis.markers.enumerated() {
            out += [
                String(index + 1), number(Double(marker.sample) / Signal.sampleRate, 2), escape(marker.label),
                marker.addedLive ? "live" : "review",
                number(response?.gsrRise), number(response?.heartRateChange), number(response?.peakLatency),
            ].joined(separator: ",") + "\n"
        }
        return out
    }

    static func summary(_ recording: ExperimentRecording, _ analysis: ExperimentAnalysis) -> String {
        var lines = [
            recording.title,
            String(repeating: "=", count: recording.title.count),
            "Template: \(ExperimentTemplate.find(recording.templateID).title)",
            "Subject: \(recording.subjectName)",
            "Recorded: \(recording.startedAt.formatted(date: .abbreviated, time: .shortened)), \(formatClock(recording.duration)) long, source: \(recording.source)",
            "",
            "Interpretation",
            "--------------",
        ]
        lines += analysis.interpretation.map { "- " + $0 }
        lines += ["", "Phases", "------"]
        for (phase, s) in analysis.phases {
            let hr = s.heartRate.map { "\(Int($0.rounded())) bpm" } ?? "—"
            let hrv = s.hrv.map { "\(Int($0.rmssd.rounded())) ms" } ?? "—"
            let br = s.breathingRate.map { String(format: "%.1f/min", $0) } ?? "—"
            lines.append("\(phase.name) (\(formatClock(s.seconds))): HR \(hr), HRV RMSSD \(hrv), breathing \(br), \(String(format: "%.1f", s.responsesPerMinute)) skin responses/min")
        }
        if !analysis.markers.isEmpty {
            lines += ["", "Markers", "-------"]
            for (marker, response) in analysis.markers {
                let detail = response.map { "GSR \(AppModel.signed($0.gsrRise, unit: nil)), HR \(AppModel.signed($0.heartRateChange, unit: "bpm"))" } ?? "too close to the edge to measure"
                lines.append("\(formatClock(Double(marker.sample) / Signal.sampleRate))  \(marker.label): \(detail)")
            }
        }
        if !recording.notes.isEmpty {
            lines += ["", "Notes", "-----", recording.notes]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
