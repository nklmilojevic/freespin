import CoreGraphics
import EventSynth
import Foundation
import HIDPP
import FreespinCore

/// One line of a trace file (JSONL). `kind` is "hid" for a decoded 0x2121 report and "cg" for a scroll CGEvent.
struct TraceRecord: Codable {
    var kind: String
    var t: UInt64                 // uptime ns when observed
    // hid
    var periods: Int?
    var deltaV: Int?
    var deltaH: Int?
    var hiRes: Bool?
    var ratchet: Bool?
    // cg (CGEventField raw values)
    var line1: Int64?
    var line2: Int64?
    var fixed1: Int64?
    var fixed2: Int64?
    var point1: Int64?
    var point2: Int64?
    var phase: Int64?
    var momentum: Int64?
    var continuous: Int64?
    var f137: Int64?
    var f55: Int64?
    var fixed1Double: Double?
    var ts: UInt64?               // CGEvent timestamp
    var ours: Bool?
}

final class TraceWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private(set) var count = 0

    init(path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: path) else { throw HIDPPError.transport("cannot open \(path)") }
        handle = h
        encoder.outputFormatting = [.sortedKeys]
    }

    func write(_ r: TraceRecord) {
        guard var data = try? encoder.encode(r) else { return }
        data.append(0x0A)
        lock.withLock {
            handle.write(data)
            count += 1
        }
    }
}

/// Listen-only tap on scroll-wheel events.
final class ScrollTap: @unchecked Sendable {
    private var tap: CFMachPort?
    private let writer: TraceWriter

    init(writer: TraceWriter) { self.writer = writer }

    func start() throws {
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: { _, type, event, ctx in
            if type == .scrollWheel, let ctx {
                Unmanaged<ScrollTap>.fromOpaque(ctx).takeUnretainedValue().record(event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: ctx) else {
            throw HIDPPError.transport("CGEventTapCreate failed (grant Input Monitoring to this terminal)")
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func record(_ e: CGEvent) {
        func i(_ raw: UInt32) -> Int64 { e.getIntegerValueField(CGEventField(rawValue: raw)!) }
        writer.write(TraceRecord(
            kind: "cg", t: DispatchTime.now().uptimeNanoseconds,
            line1: i(11), line2: i(12), fixed1: i(93), fixed2: i(94), point1: i(96), point2: i(97),
            phase: i(99), momentum: i(123), continuous: i(88), f137: i(137), f55: i(55),
            fixed1Double: e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            ts: e.timestamp, ours: e.getIntegerValueField(.eventSourceUserData) == ScrollEventPoster.eventSourceUserData))
    }
}

func runTrace(path: String) async throws {
    let writer = try TraceWriter(path: path)
    let tap = ScrollTap(writer: writer)
    try tap.start()
    let (_, sessions) = try await discover()
    for s in sessions where s.snapshot.has(.hiResWheel) {
        try await s.device.onWheelEvent { ev in
            let t = DispatchTime.now().uptimeNanoseconds
            switch ev {
            case let .movement(hiRes, periods, dV, dH):
                writer.write(TraceRecord(kind: "hid", t: t, periods: periods, deltaV: dV, deltaH: dH, hiRes: hiRes))
            case let .ratchetSwitch(r):
                writer.write(TraceRecord(kind: "hid", t: t, ratchet: r))
            }
        }
    }
    print("tracing \(sessions.count) device(s) → \(path); scroll, then Ctrl-C")
    await waitForInterrupt()
    print("wrote \(writer.count) records")
    withExtendedLifetime(tap) {}
}
