import AppKit
import SwiftUI

/// After-recording view: the whole experiment on a zoomable timeline, with markers you can add
/// (double-click), rename and delete, plus per-phase statistics and a plain-language interpretation.
struct ReviewView: View {
    @Bindable var model: AppModel
    @State private var titleDraft = ""

    private static let zoomChoices: [(label: String, seconds: Double)] = [("10s", 10), ("30s", 30), ("1m", 60), ("5m", 300), ("All", 0)]

    var body: some View {
        if let recording = model.review {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    header(recording)
                    Divider()
                    ReviewTimeline(recording: recording, range: visibleRange(recording)) { sample in
                        model.addReviewMarker(at: sample)
                    }
                    Divider()
                    footer(recording)
                }
                Divider()
                ReviewSidebar(model: model, recording: recording)
                    .frame(width: 380)
            }
            .onAppear { titleDraft = recording.title }
            .onChange(of: recording.id) { titleDraft = recording.title }
        }
    }

    private func visibleRange(_ recording: ExperimentRecording) -> Range<Int> {
        let zoom = model.reviewZoom
        guard zoom > 0, zoom < recording.duration else { return 0..<recording.sampleCount }
        let start = min(Signal.samples(model.reviewWindowStart), max(0, recording.sampleCount - Signal.samples(zoom)))
        return start..<min(recording.sampleCount, start + Signal.samples(zoom))
    }

    private func header(_ recording: ExperimentRecording) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Title", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .onSubmit { model.updateReviewText(title: titleDraft) }
                Text("\(ExperimentTemplate.find(recording.templateID).title) · \(recording.subjectName) · \(recording.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(formatClock(recording.duration))\(recording.source == "simulator" ? " · simulated" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Zoom", selection: $model.reviewZoom) {
                ForEach(Self.zoomChoices, id: \.seconds) { Text($0.label).tag($0.seconds) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
            Button("Back to Live", systemImage: "waveform.path.ecg") { model.closeReview() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func footer(_ recording: ExperimentRecording) -> some View {
        let range = visibleRange(recording)
        let zoomed = range.count < recording.sampleCount
        return HStack(spacing: 12) {
            if zoomed {
                Slider(value: $model.reviewWindowStart, in: 0...max(0.1, recording.duration - model.reviewZoom))
                Text("\(formatClock(Double(range.lowerBound) / Signal.sampleRate))–\(formatClock(Double(range.upperBound) / Signal.sampleRate)) of \(formatClock(recording.duration))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("Whole recording, \(formatClock(recording.duration))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text("Double-click a trace to add a marker")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Timeline

private struct ReviewTimeline: View {
    let recording: ExperimentRecording
    let range: Range<Int>
    let onDoubleClick: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEach(Channel.displayOrder) { channel in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel.title).font(.headline).foregroundStyle(channel.color)
                        Text(channel.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
                }
            }
            .frame(width: 150)
            Divider()
            GeometryReader { geo in
                Canvas { context, size in
                    draw(in: &context, size: size)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture(count: 2).onEnded { value in
                    let fraction = min(max(value.location.x / max(geo.size.width, 1), 0), 1)
                    onDoubleClick(range.lowerBound + Int(fraction * Double(range.count)))
                })
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func x(_ sample: Int, _ width: CGFloat) -> CGFloat {
        width * CGFloat(sample - range.lowerBound) / CGFloat(max(range.count - 1, 1))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard range.count > 1 else { return }
        let laneHeight = size.height / 3
        let axisSpace: CGFloat = 16

        // Phases: shaded bands with their names.
        for (index, phase) in recording.phases.enumerated() where phase.end > range.lowerBound && phase.start < range.upperBound {
            let x0 = x(max(phase.start, range.lowerBound), size.width)
            let x1 = x(min(phase.end, range.upperBound - 1), size.width)
            context.fill(Path(CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: size.height)), with: .color(PhasePalette.color(index).opacity(0.09)))
            context.draw(Text(phase.name).font(.caption.weight(.semibold)).foregroundStyle(PhasePalette.color(index)), at: CGPoint(x: x0 + 4, y: 4), anchor: .topLeading)
        }

        // Time grid.
        let visibleSeconds = Double(range.count) / Signal.sampleRate
        let step = visibleSeconds <= 15 ? 1.0 : visibleSeconds <= 60 ? 5 : visibleSeconds <= 300 ? 30 : visibleSeconds <= 900 ? 60 : 300
        var grid = Path()
        var t = (Double(range.lowerBound) / Signal.sampleRate / step).rounded(.up) * step
        while t * Signal.sampleRate < Double(range.upperBound) {
            let gx = x(Int(t * Signal.sampleRate), size.width)
            grid.move(to: CGPoint(x: gx, y: 0))
            grid.addLine(to: CGPoint(x: gx, y: size.height - axisSpace))
            context.draw(Text(formatClock(t)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary), at: CGPoint(x: min(max(gx, 14), size.width - 14), y: size.height - 2), anchor: .bottom)
            t += step
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)

        // Traces, one lane per channel, downsampled to min/max per pixel column.
        for (lane, channel) in Channel.displayOrder.enumerated() {
            let values = recording.channels[channel.rawValue][range]
            guard let low = values.min(), let high = values.max() else { continue }
            let span = max(high - low, 20) * 1.1
            let center = (low + high) / 2
            let top = CGFloat(lane) * laneHeight + 18
            let height = laneHeight - 26 - (lane == 2 ? axisSpace : 0)
            func y(_ v: Double) -> CGFloat { top + height * CGFloat(0.5 - (v - center) / span) }

            var trace = Path()
            let columns = max(Int(size.width), 1)
            let perColumn = Double(range.count) / Double(columns)
            if perColumn <= 2 {
                for (i, v) in values.enumerated() {
                    let point = CGPoint(x: x(range.lowerBound + i, size.width), y: y(v))
                    if i == 0 { trace.move(to: point) } else { trace.addLine(to: point) }
                }
            } else {
                for column in 0..<columns {
                    let lo = range.lowerBound + Int(Double(column) * perColumn)
                    let hi = min(range.upperBound, range.lowerBound + Int(Double(column + 1) * perColumn))
                    guard hi > lo else { continue }
                    let slice = recording.channels[channel.rawValue][lo..<hi]
                    let px = CGFloat(column)
                    let a = CGPoint(x: px, y: y(slice.min() ?? 0))
                    let b = CGPoint(x: px, y: y(slice.max() ?? 0))
                    if column == 0 { trace.move(to: a) } else { trace.addLine(to: a) }
                    trace.addLine(to: b)
                }
            }
            context.stroke(trace, with: .color(channel.color), style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))

            if lane > 0 {
                var divider = Path()
                divider.move(to: CGPoint(x: 0, y: CGFloat(lane) * laneHeight))
                divider.addLine(to: CGPoint(x: size.width, y: CGFloat(lane) * laneHeight))
                context.stroke(divider, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
            }
        }

        // Markers.
        for (index, marker) in recording.markers.sorted(by: { $0.sample < $1.sample }).enumerated() where range.contains(marker.sample) {
            let mx = x(marker.sample, size.width)
            var line = Path()
            line.move(to: CGPoint(x: mx, y: 0))
            line.addLine(to: CGPoint(x: mx, y: size.height - axisSpace))
            context.stroke(line, with: .color(.pink.opacity(0.9)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            // Stagger labels on three rows so neighbouring markers don't overprint each other.
            context.draw(
                Text("\(index + 1) \(marker.label)").font(.caption2.weight(.bold)).foregroundStyle(.pink),
                at: CGPoint(x: mx + 3, y: 20 + CGFloat(index % 3) * 13),
                anchor: .topLeading
            )
        }
    }
}

// MARK: - Sidebar

private struct ReviewSidebar: View {
    @Bindable var model: AppModel
    let recording: ExperimentRecording
    @State private var notesDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let analysis = model.reviewAnalysis {
                    SectionCard("Interpretation") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(analysis.interpretation.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("•").foregroundStyle(.secondary)
                                    Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    phasesCard(analysis)
                    hrvCard(analysis)
                    markersCard(analysis)
                }

                SectionCard("Notes") {
                    TextEditor(text: $notesDraft)
                        .font(.callout)
                        .frame(height: 80)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .onChange(of: notesDraft) { model.updateReviewText(notes: notesDraft) }
                }

                SectionCard("Files") {
                    if let status = model.reviewSaveStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("experiment.json, signals.csv, phases.csv, markers.csv, beats.csv (for HRV tools) and summary.txt. Marker edits are saved automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let folder = recording.folder {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                            .controlSize(.small)
                    }
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { notesDraft = recording.notes }
        .onChange(of: recording.id) { notesDraft = recording.notes }
    }

    private func phasesCard(_ analysis: ExperimentAnalysis) -> some View {
        SectionCard("Phases") {
            if analysis.phases.isEmpty {
                Text("No phases in this recording.").font(.caption).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Phase")
                        Text("HR").gridColumnAlignment(.trailing)
                        Text("HRV").gridColumnAlignment(.trailing)
                        Text("Breaths").gridColumnAlignment(.trailing)
                        Text("Skin/min").gridColumnAlignment(.trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    ForEach(Array(analysis.phases.enumerated()), id: \.element.phase.id) { index, item in
                        GridRow {
                            Button {
                                model.jumpReview(toSample: item.phase.start)
                            } label: {
                                HStack(spacing: 5) {
                                    RoundedRectangle(cornerRadius: 2).fill(PhasePalette.color(index)).frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(item.phase.name).lineLimit(1)
                                        Text(formatClock(item.stats.seconds)).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            Text(item.stats.heartRate.map { "\(Int($0.rounded()))" } ?? "—")
                            Text(item.stats.hrv.map { "\(Int($0.rmssd.rounded())) ms" } ?? "—")
                            Text(item.stats.breathingRate.map { String(format: "%.1f", $0) } ?? "—")
                            Text(String(format: "%.1f", item.stats.responsesPerMinute))
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
                Text("HR in bpm, HRV as RMSSD, breaths per minute, skin responses per minute. Click a phase to jump to it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func hrvCard(_ analysis: ExperimentAnalysis) -> some View {
        SectionCard("Heart Rate Variability") {
            if let hrv = analysis.overall.hrv {
                HStack(spacing: 18) {
                    stat("RMSSD", "\(Int(hrv.rmssd.rounded())) ms")
                    stat("SDNN", "\(Int(hrv.sdnn.rounded())) ms")
                    stat("Mean HR", "\(Int(hrv.meanHeartRate.rounded())) bpm")
                    stat("Beats", "\(hrv.beats)")
                }
            } else {
                Text("Not enough clean heartbeats to measure HRV.").font(.callout).foregroundStyle(.secondary)
            }
            Text("HRV is the variation between heartbeats. RMSSD tracks the fast, breath-by-breath changes driven by the vagus nerve (\"rest and digest\"): it's higher when relaxed and drops with stress or effort. SDNN includes slower swings too. Only compare phases of similar length, and treat values from a finger pulse sensor as estimates.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func markersCard(_ analysis: ExperimentAnalysis) -> some View {
        SectionCard("Markers") {
            if analysis.markers.isEmpty {
                Text("No markers yet. Double-click a trace to add one at that moment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(analysis.markers.enumerated()), id: \.element.marker.id) { index, item in
                        MarkerRow(model: model, number: index + 1, marker: item.marker, response: item.response)
                    }
                }
                Text("Response = skin-conductance rise and peak heart-rate change in the 10 s after each marker.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold).monospacedDigit())
        }
    }
}

private struct MarkerRow: View {
    @Bindable var model: AppModel
    let number: Int
    let marker: ExperimentMarker
    let response: MarkerResponse?
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button("\(number) · \(formatClock(Double(marker.sample) / Signal.sampleRate))") {
                    model.jumpReview(toSample: marker.sample)
                }
                .buttonStyle(.link)
                .font(.caption.monospacedDigit())
                TextField("Label", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { model.renameMarker(marker.id, to: draft) }
                Button {
                    model.deleteMarker(marker.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete marker")
            }
            Text(response.map { "GSR \(AppModel.signed($0.gsrRise, unit: nil)) · HR \(AppModel.signed($0.heartRateChange, unit: "bpm")) · peak after \(String(format: "%.1f", $0.peakLatency)) s" } ?? "Too close to the start or end to measure")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            + Text(marker.addedLive ? "" : " · added in review").font(.caption2).foregroundStyle(.tertiary)
        }
        .onAppear { draft = marker.label }
        .onChange(of: marker.label) { draft = marker.label }
    }
}
