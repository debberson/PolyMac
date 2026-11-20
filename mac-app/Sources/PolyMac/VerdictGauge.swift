import SwiftUI

/// Half-dial from "truthful" (left, green) to "deceptive" (right, red) with an inconclusive middle.
struct VerdictGauge: View {
    let reading: VerdictReading?
    let isLive: Bool

    private static let zones: [(from: Double, to: Double, color: Color)] = [
        (0, 0.4, .green), (0.4, 0.6, .yellow), (0.6, 1, .red),
    ]

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height - 8)
                let radius = max(min(geo.size.width / 2, geo.size.height) - 16, 10)
                let needle = radius - 14
                ZStack {
                    Canvas { context, _ in
                        for zone in Self.zones {
                            var arc = Path()
                            arc.addArc(center: center, radius: radius, startAngle: angle(zone.from), endAngle: angle(zone.to), clockwise: false)
                            context.stroke(arc, with: .color(zone.color.opacity(reading == nil ? 0.25 : 0.85)), style: StrokeStyle(lineWidth: 16))
                        }
                    }
                    if let reading {
                        Capsule()
                            .fill(.primary)
                            .frame(width: 4, height: needle)
                            .position(x: center.x, y: center.y - needle / 2)
                            .rotationEffect(
                                .degrees(-90 + 180 * reading.gauge),
                                anchor: UnitPoint(x: center.x / geo.size.width, y: center.y / geo.size.height)
                            )
                    }
                    Circle()
                        .fill(.primary)
                        .frame(width: 12, height: 12)
                        .position(center)
                    if isLive {
                        Text("LIVE")
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.red))
                            .foregroundStyle(.white)
                            .position(x: geo.size.width - 22, y: 10)
                    }
                }
                .animation(.spring(duration: 0.6), value: reading?.gauge)
            }
            Text(reading?.verdict.title ?? "No verdict yet")
                .font(.title3.weight(.bold))
                .foregroundStyle(reading?.verdict.color ?? .secondary)
            HStack {
                Text("Truthful")
                Spacer()
                Text("Deceptive")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    /// 0 → pointing left, 0.5 → up, 1 → right.
    private func angle(_ value: Double) -> Angle { .degrees(180 + 180 * value) }
}
