import Foundation
import Testing
@testable import PolyMac

private func wave(center: Double, amplitude: Double, count: Int = 500) -> [Double] {
    (0..<count).map { center + amplitude * sin(Double($0) / 20) }
}

/// Feeds enough frames for the glide to settle.
@MainActor private func settle(_ scales: ChartScales, _ values: [Double], auto: Bool = true) -> ClosedRange<Double> {
    var range = scales.range(for: .gsr, values: values, auto: auto)
    for _ in 0..<120 { range = scales.range(for: .gsr, values: values, auto: auto) }
    return range
}

@MainActor @Test func autoScaleIgnoresSmallDrift() {
    let scales = ChartScales()
    let start = settle(scales, wave(center: 500, amplitude: 40))
    // A small drift and a slightly smaller swing stay inside the headroom: no rescale.
    #expect(settle(scales, wave(center: 505, amplitude: 36)) == start)
}

@MainActor @Test func autoScaleWidensWhenTraceEscapes() {
    let scales = ChartScales()
    _ = settle(scales, wave(center: 500, amplitude: 40))
    let wider = settle(scales, wave(center: 500, amplitude: 120))
    #expect(wider.lowerBound <= 380 && wider.upperBound >= 620)
}

@MainActor @Test func autoScaleNarrowsOnlyWhenTraceShrinksALot() {
    let scales = ChartScales()
    let start = settle(scales, wave(center: 500, amplitude: 100))
    #expect(settle(scales, wave(center: 500, amplitude: 60)) == start)  // 60% of before: hold
    let narrow = settle(scales, wave(center: 500, amplitude: 20))       // 20%: tighten
    #expect(narrow.upperBound - narrow.lowerBound < 80)
}

@MainActor @Test func heldScaleNeverMovesUntilFitOrZoom() {
    let scales = ChartScales()
    let held = settle(scales, wave(center: 500, amplitude: 40), auto: false)
    #expect(settle(scales, wave(center: 700, amplitude: 150), auto: false) == held)

    scales.zoom(.gsr, by: 0.5)
    let zoomed = scales.range(for: .gsr, values: wave(center: 700, amplitude: 150), auto: false)
    #expect(abs((zoomed.upperBound - zoomed.lowerBound) - (held.upperBound - held.lowerBound) / 2) < 0.001)

    scales.fitNow(.gsr)
    let fitted = scales.range(for: .gsr, values: wave(center: 700, amplitude: 150), auto: false)
    #expect(fitted.contains(550) && fitted.contains(850))
}
