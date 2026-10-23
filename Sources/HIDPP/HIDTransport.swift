import Foundation
import IOKit
import IOKit.hid

/// A byte pipe to one HID++ capable HID interface. Abstracted so tests can replay captured traffic.
public protocol HIDPPTransport: AnyObject, Sendable {
    /// Sends one raw report (report ID as the first byte).
    func send(_ report: [UInt8]) throws
    /// Installs the handler that receives every raw input report (report ID first).
    func setInputHandler(_ handler: @escaping @Sendable ([UInt8]) -> Void)
}

/// Identity of a HID interface as reported by IOKit.
public struct HIDInterfaceInfo: Sendable, Hashable, CustomStringConvertible {
    public var vendorID: Int
    public var productID: Int
    public var product: String
    public var transport: String
    public var usagePage: Int
    public var usage: Int
    public var locationID: Int
    public var serial: String
    public var maxInputReportSize: Int
    public var maxOutputReportSize: Int

    public var isBluetooth: Bool { transport.localizedCaseInsensitiveContains("bluetooth") }

    public var description: String {
        String(format: "%@ [%04x:%04x] %@ page 0x%04x/0x%04x", product, vendorID, productID, transport, usagePage, usage)
    }
}

/// Runs IOKit HID callbacks on one dedicated thread with its own run loop.
final class HIDRunLoopThread: Thread, @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private(set) var runLoop: RunLoop!

    override init() {
        super.init()
        name = "freespin.hid"
        qualityOfService = .userInteractive
    }

    func startAndWait() {
        start()
        ready.wait()
    }

    override func main() {
        runLoop = RunLoop.current
        // Keep the run loop alive even with no sources yet.
        runLoop.add(NSMachPort(), forMode: .default)
        ready.signal()
        while !isCancelled {
            runLoop.run(mode: .default, before: .distantFuture)
        }
    }

    /// Runs `block` on the HID thread and waits for it.
    func sync<T>(_ block: @escaping () -> T) -> T {
        if Thread.current == self { return block() }
        var result: T!
        let done = DispatchSemaphore(value: 0)
        let cf = runLoop.getCFRunLoop()
        CFRunLoopPerformBlock(cf, CFRunLoopMode.defaultMode.rawValue) {
            result = block()
            done.signal()
        }
        CFRunLoopWakeUp(cf)
        done.wait()
        return result
    }
}

/// A HID++ interface backed by an `IOHIDDevice`.
public final class IOHIDTransport: HIDPPTransport, @unchecked Sendable {
    public let info: HIDInterfaceInfo
    let device: IOHIDDevice
    private let lock = NSLock()
    private var handler: (@Sendable ([UInt8]) -> Void)?
    private var inputBuffer: UnsafeMutablePointer<UInt8>
    private let bufferSize: Int
    private var opened = false

    init(device: IOHIDDevice, info: HIDInterfaceInfo, runLoop: RunLoop) throws {
        self.device = device
        self.info = info
        bufferSize = max(info.maxInputReportSize, 64)
        inputBuffer = .allocate(capacity: bufferSize)
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            // deinit still runs for a fully initialised class whose init throws; it frees the buffer.
            throw HIDPPError.transport(String(format: "IOHIDDeviceOpen failed 0x%08x", result))
        }
        opened = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, bufferSize, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            let transport = Unmanaged<IOHIDTransport>.fromOpaque(context).takeUnretainedValue()
            var bytes = Array(UnsafeBufferPointer(start: report, count: length))
            // IOKit strips the report ID from some interfaces; restore it so framing is uniform.
            if bytes.first != UInt8(truncatingIfNeeded: reportID) {
                bytes.insert(UInt8(truncatingIfNeeded: reportID), at: 0)
            }
            transport.deliver(bytes)
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, runLoop.getCFRunLoop(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        if opened { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        inputBuffer.deallocate()
    }

    private func deliver(_ bytes: [UInt8]) {
        lock.lock()
        let h = handler
        lock.unlock()
        h?(bytes)
    }

    public func setInputHandler(_ handler: @escaping @Sendable ([UInt8]) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    public func send(_ report: [UInt8]) throws {
        guard let id = report.first else { return }
        let result = report.withUnsafeBufferPointer { buf in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(id), buf.baseAddress!, buf.count)
        }
        guard result == kIOReturnSuccess else {
            throw HIDPPError.transport(String(format: "IOHIDDeviceSetReport failed 0x%08x", result))
        }
    }
}

/// Discovers Logitech HID++ interfaces (VID 0x046D, vendor usage pages 0xFF00 and 0xFF43),
/// mirroring the matching dictionaries of the Options+ agent (`devio::MacOSBus::createMatchingDict`).
public final class HIDManager: @unchecked Sendable {
    public static let logitechVendorID = 0x046D

    public struct Event: Sendable {
        public enum Kind: Sendable { case added, removed }
        public var kind: Kind
        public var info: HIDInterfaceInfo
        public var transport: IOHIDTransport?
    }

    private let thread = HIDRunLoopThread()
    private var manager: IOHIDManager!
    private var transports: [IOHIDDevice: IOHIDTransport] = [:]
    private var onEvent: (@Sendable (Event) -> Void)?

    public init() {
        thread.startAndWait()
    }

    /// Starts matching and calls `handler` (on the HID thread) for every add/remove.
    public func start(_ handler: @escaping @Sendable (Event) -> Void) throws {
        onEvent = handler
        let status: IOReturn = thread.sync { [self] in
            manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            let matches: [[String: Any]] = [
                [kIOHIDVendorIDKey: Self.logitechVendorID, kIOHIDDeviceUsagePageKey: 0xFF00],
                [kIOHIDVendorIDKey: Self.logitechVendorID, kIOHIDDeviceUsagePageKey: 0xFF43],
            ]
            IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
                guard let context else { return }
                Unmanaged<HIDManager>.fromOpaque(context).takeUnretainedValue().added(device)
            }, context)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
                guard let context else { return }
                Unmanaged<HIDManager>.fromOpaque(context).takeUnretainedValue().removed(device)
            }, context)
            IOHIDManagerScheduleWithRunLoop(manager, thread.runLoop.getCFRunLoop(), CFRunLoopMode.defaultMode.rawValue)
            return IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        guard status == kIOReturnSuccess else {
            throw HIDPPError.transport(String(format: "IOHIDManagerOpen failed 0x%08x (Input Monitoring permission?)", status))
        }
    }

    public func stop() {
        thread.sync { [self] in
            if let manager {
                IOHIDManagerUnscheduleFromRunLoop(manager, thread.runLoop.getCFRunLoop(), CFRunLoopMode.defaultMode.rawValue)
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            transports.removeAll()
        }
    }

    private func added(_ device: IOHIDDevice) {
        let info = Self.info(for: device)
        do {
            let transport = try IOHIDTransport(device: device, info: info, runLoop: thread.runLoop)
            transports[device] = transport
            onEvent?(Event(kind: .added, info: info, transport: transport))
        } catch {
            onEvent?(Event(kind: .added, info: info, transport: nil))
        }
    }

    private func removed(_ device: IOHIDDevice) {
        let info = Self.info(for: device)
        transports[device] = nil
        onEvent?(Event(kind: .removed, info: info, transport: nil))
    }

    static func info(for device: IOHIDDevice) -> HIDInterfaceInfo {
        func int(_ key: String) -> Int { (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0 }
        func str(_ key: String) -> String { (IOHIDDeviceGetProperty(device, key as CFString) as? String) ?? "" }
        return HIDInterfaceInfo(
            vendorID: int(kIOHIDVendorIDKey), productID: int(kIOHIDProductIDKey),
            product: str(kIOHIDProductKey), transport: str(kIOHIDTransportKey),
            usagePage: int(kIOHIDPrimaryUsagePageKey), usage: int(kIOHIDPrimaryUsageKey),
            locationID: int(kIOHIDLocationIDKey), serial: str(kIOHIDSerialNumberKey),
            maxInputReportSize: int(kIOHIDMaxInputReportSizeKey), maxOutputReportSize: int(kIOHIDMaxOutputReportSizeKey))
    }
}
