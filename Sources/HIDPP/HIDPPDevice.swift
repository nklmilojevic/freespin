import Foundation

/// A HID++ 2.0 device reachable through a transport at a given device index.
///
/// Requests are serialised per device (HID++ devices handle one request at a time well; Options+ also
/// serialises via `devio::DeviceRequest`). Responses are matched by feature index, function and software ID.
public final class HIDPPDevice: @unchecked Sendable {
    public typealias NotificationHandler = @Sendable (HIDPPMessage) -> Void

    public let transport: HIDPPTransport
    public let deviceIndex: UInt8
    public var requestTimeout: TimeInterval = 2.0
    public var retries = 1

    private let lock = NSLock()
    private let requestGate = AsyncSemaphore(value: 1)
    private var pending: Pending?
    private var nextSoftwareID: UInt8 = 1
    private var featureIndexes: [UInt16: UInt8] = [:]
    private var notificationHandlers: [UInt8: [UUID: NotificationHandler]] = [:]
    private var anyHandlers: [UUID: NotificationHandler] = [:]

    private final class Pending {
        let featureIndex: UInt8
        let function: UInt8
        let softwareID: UInt8
        let continuation: CheckedContinuation<[UInt8], Error>
        var finished = false
        init(featureIndex: UInt8, function: UInt8, softwareID: UInt8, continuation: CheckedContinuation<[UInt8], Error>) {
            self.featureIndex = featureIndex
            self.function = function
            self.softwareID = softwareID
            self.continuation = continuation
        }
    }

    public init(transport: HIDPPTransport, deviceIndex: UInt8 = HIDPPDeviceIndex.direct) {
        self.transport = transport
        self.deviceIndex = deviceIndex
    }

    /// Must be called once so the device receives input. For receivers, a router calls `handle(_:)` instead.
    public func attach() {
        transport.setInputHandler { [weak self] raw in
            guard let self, let msg = HIDPPMessage(raw: raw), msg.deviceIndex == self.deviceIndex else { return }
            self.handle(msg)
        }
    }

    // MARK: - Notifications

    /// Subscribes to notifications (software ID 0) from one feature index.
    @discardableResult
    public func onNotification(featureIndex: UInt8, _ handler: @escaping NotificationHandler) -> UUID {
        let id = UUID()
        lock.withLock { notificationHandlers[featureIndex, default: [:]][id] = handler }
        return id
    }

    @discardableResult
    public func onAnyNotification(_ handler: @escaping NotificationHandler) -> UUID {
        let id = UUID()
        lock.withLock { anyHandlers[id] = handler }
        return id
    }

    public func removeHandler(_ id: UUID) {
        lock.withLock {
            anyHandlers[id] = nil
            for key in notificationHandlers.keys { notificationHandlers[key]?[id] = nil }
        }
    }

    // MARK: - Requests

    /// Sends a request to `featureIndex`/`function` and returns the response parameters.
    public func request(featureIndex: UInt8, function: UInt8, parameters: [UInt8] = [],
                        reportID: HIDPPReportID = .long) async throws -> [UInt8] {
        await requestGate.wait()
        defer { requestGate.signal() }
        var lastError: Error = HIDPPError.timeout
        for _ in 0...retries {
            do {
                return try await sendOnce(featureIndex: featureIndex, function: function,
                                          parameters: parameters, reportID: reportID)
            } catch HIDPPError.timeout {
                lastError = HIDPPError.timeout
                continue
            } catch HIDPPError.device(.busy) {
                lastError = HIDPPError.device(.busy)
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
        }
        throw lastError
    }

    /// Resolves a feature ID to its index via Root (0x0000) GetFeature, caching the result.
    public func featureIndex(for featureID: UInt16) async throws -> UInt8 {
        if featureID == 0x0000 { return 0 }
        if let cached = lock.withLock({ featureIndexes[featureID] }) { return cached }
        let resp = try await request(featureIndex: 0, function: 0,
                                     parameters: [UInt8(featureID >> 8), UInt8(featureID & 0xFF)])
        let index = resp.byte(0)
        guard index != 0 else { throw HIDPPError.featureNotSupported(featureID) }
        lock.withLock { featureIndexes[featureID] = index }
        return index
    }

    public func hasFeature(_ featureID: UInt16) async -> Bool {
        (try? await featureIndex(for: featureID)) != nil
    }

    /// Convenience: request on a feature by ID.
    public func request(feature featureID: UInt16, function: UInt8, parameters: [UInt8] = []) async throws -> [UInt8] {
        let index = try await featureIndex(for: featureID)
        return try await request(featureIndex: index, function: function, parameters: parameters)
    }

    public func cachedFeatureIndex(_ featureID: UInt16) -> UInt8? {
        lock.withLock { featureIndexes[featureID] }
    }

    /// Clears cached feature indexes (e.g. after reconnect or a FeatureSet change).
    public func invalidateFeatureCache() {
        lock.withLock { featureIndexes.removeAll() }
    }

    private func sendOnce(featureIndex: UInt8, function: UInt8, parameters: [UInt8],
                          reportID: HIDPPReportID) async throws -> [UInt8] {
        let swid = lock.withLock { () -> UInt8 in
            let id = nextSoftwareID
            nextSoftwareID = nextSoftwareID >= 0x0F ? 1 : nextSoftwareID + 1
            return id
        }
        let message = HIDPPMessage(reportID: reportID, deviceIndex: deviceIndex, featureIndex: featureIndex,
                                   function: function, softwareID: swid, parameters: parameters)
        let timeout = requestTimeout
        return try await withCheckedThrowingContinuation { continuation in
            let pendingRequest = Pending(featureIndex: featureIndex, function: function & 0x0F,
                                         softwareID: swid, continuation: continuation)
            lock.withLock { pending = pendingRequest }
            do {
                try transport.send(message.encoded())
            } catch {
                finish(pendingRequest, with: .failure(error))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(pendingRequest, with: .failure(HIDPPError.timeout))
            }
        }
    }

    private func finish(_ request: Pending, with result: Result<[UInt8], Error>) {
        let shouldResume: Bool = lock.withLock {
            guard !request.finished else { return false }
            request.finished = true
            if pending === request { pending = nil }
            return true
        }
        if shouldResume { request.continuation.resume(with: result) }
    }

    /// Entry point for every message addressed to this device index.
    public func handle(_ msg: HIDPPMessage) {
        let current = lock.withLock { pending }
        if let current {
            if msg.featureIndex == HIDPPMessage.errorFeatureIndex20,
               msg.parameters.byte(0) == current.featureIndex,
               msg.parameters.byte(1) == (current.function << 4 | current.softwareID) {
                let code = HIDPP20Error(rawValue: msg.parameters.byte(2)) ?? .unknown
                finish(current, with: .failure(HIDPPError.device(code)))
                return
            }
            if msg.featureIndex == HIDPPMessage.errorSubID10, msg.parameters.byte(0) == current.featureIndex {
                finish(current, with: .failure(HIDPPError.device10(msg.parameters.byte(2))))
                return
            }
            if msg.featureIndex == current.featureIndex, msg.function == current.function,
               msg.softwareID == current.softwareID {
                finish(current, with: .success(msg.parameters))
                return
            }
        }
        guard msg.isNotification else { return }
        let handlers: [NotificationHandler] = lock.withLock {
            Array((notificationHandlers[msg.featureIndex] ?? [:]).values) + Array(anyHandlers.values)
        }
        for handler in handlers { handler(msg) }
    }
}

/// Minimal async semaphore used to serialise requests.
final class AsyncSemaphore: @unchecked Sendable {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()

    init(value: Int) { self.value = value }

    func wait() async {
        let acquired: Bool = lock.withLock {
            if value > 0 { value -= 1; return true }
            return false
        }
        if acquired { return }
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if value > 0 { value -= 1; return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func signal() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty { value += 1; return nil }
            return waiters.removeFirst()
        }
        waiter?.resume()
    }
}
