import Foundation
import SwiftUI

/// One sample of all three channels, as raw 10-bit ADC counts (0–1023 on an Uno).
struct Reading: Sendable, Equatable {
    /// `millis()` from the board when the firmware sends CSV; nil in Serial Plotter mode.
    var deviceMillis: UInt32?
    var resp: Double
    var pulse: Double
    var gsr: Double

    func value(for channel: Channel) -> Double {
        switch channel {
        case .resp: resp
        case .pulse: pulse
        case .gsr: gsr
        }
    }
}

enum Channel: Int, CaseIterable, Identifiable, Sendable {
    case resp, pulse, gsr

    var id: Int { rawValue }

    /// Classic polygraph chart order: pneumograph on top, GSR in the middle, cardio at the bottom.
    static let displayOrder: [Channel] = [.resp, .gsr, .pulse]

    var title: String {
        switch self {
        case .resp: "Respiration"
        case .pulse: "Pulse"
        case .gsr: "GSR"
        }
    }

    var subtitle: String {
        switch self {
        case .resp: "Pneumograph · A0"
        case .pulse: "Cardiosphygmograph · A1"
        case .gsr: "Galvanograph · A2"
        }
    }

    var color: Color {
        switch self {
        case .resp: .blue
        case .pulse: .red
        case .gsr: .green
        }
    }
}

/// Parses one line from the firmware. Accepts both output modes of `polymac_firmware_v0`:
/// - CSV: `timestamp_ms,resp,pulse,gsr` (or just `resp,pulse,gsr`)
/// - Serial Plotter: `resp:512,pulse:498,gsr:301`
enum SampleParser {
    static func parse(_ raw: String) -> Reading? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        if line.contains(":") {
            var values: [String: Double] = [:]
            for field in fields {
                let pair = field.split(separator: ":", maxSplits: 1)
                guard pair.count == 2, let value = Double(pair[1]) else { return nil }
                values[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] = value
            }
            guard let resp = values["resp"], let pulse = values["pulse"], let gsr = values["gsr"] else {
                return nil
            }
            return Reading(deviceMillis: nil, resp: resp, pulse: pulse, gsr: gsr)
        }

        let numbers = fields.compactMap(Double.init)
        guard numbers.count == fields.count else { return nil }
        switch numbers.count {
        case 4:
            guard let millis = UInt32(exactly: numbers[0]) else { return nil }
            return Reading(deviceMillis: millis, resp: numbers[1], pulse: numbers[2], gsr: numbers[3])
        case 3:
            return Reading(deviceMillis: nil, resp: numbers[0], pulse: numbers[1], gsr: numbers[2])
        default:
            return nil
        }
    }
}
