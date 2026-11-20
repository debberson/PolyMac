import Testing
@testable import PolyMac

@Test func parsesCSVWithTimestamp() {
    #expect(SampleParser.parse("1234,512,498,301\r\n") == Reading(deviceMillis: 1234, resp: 512, pulse: 498, gsr: 301))
}

@Test func parsesCSVWithoutTimestamp() {
    #expect(SampleParser.parse("512,498,301") == Reading(deviceMillis: nil, resp: 512, pulse: 498, gsr: 301))
}

@Test func parsesSerialPlotterFormat() {
    #expect(SampleParser.parse("resp:512,pulse:498,gsr:301") == Reading(deviceMillis: nil, resp: 512, pulse: 498, gsr: 301))
    #expect(SampleParser.parse("gsr:3, resp:1 ,pulse:2") == Reading(deviceMillis: nil, resp: 1, pulse: 2, gsr: 3))
}

@Test func rejectsGarbage() {
    for line in ["", "hello", "1,2", "1,2,3,4,5", "\u{FFFD}12,4", "resp:1,pulse:2", "-5,1,2,3", "1,,2,3"] {
        #expect(SampleParser.parse(line) == nil, "\(line)")
    }
}

@Test func bufferReturnsMostRecentSamplesInOrder() {
    let buffer = SampleBuffer(capacity: 4)
    for i in 0..<6 {
        buffer.append(Reading(deviceMillis: nil, resp: Double(i), pulse: 0, gsr: 0))
    }
    let snapshot = buffer.snapshot(last: 3)
    #expect(snapshot.channels[Channel.resp.rawValue] == [3, 4, 5])
    #expect(snapshot.total == 6)
    #expect(buffer.snapshot(last: 10).channels[Channel.resp.rawValue] == [2, 3, 4, 5])
}
