import EventSynth
import Foundation
import FreespinCore
import IOKit.hid

let daemonUsage = """
usage: freespinctl daemon [--config <file>] [--check]

Runs Freespin headless: drives every connected device with the settings in <file>. Meant to run as a
LaunchAgent; SIGTERM or Ctrl-C gives the wheels back to macOS, SIGHUP reloads the config.

  --config <file>   JSON config (default: $XDG_CONFIG_HOME/freespin/config.json or
                    ~/.config/freespin/config.json; a missing default file means an empty config)
  --check           validate the config and exit
"""

struct DaemonOptions {
    var config: URL?
    var check = false

    static var defaultConfig: URL {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("freespin/config.json")
    }

    init(_ args: [String]) throws {
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--config":
                guard let v = it.next() else { throw ConfigError(message: "--config needs a file") }
                config = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
            case "--check": check = true
            default: throw ConfigError(message: "unknown option \(a)\n\n\(daemonUsage)")
            }
        }
    }

    /// An explicit --config must exist; the default location may be absent.
    func loadConfig() throws -> FreespinConfig {
        let url = config ?? Self.defaultConfig
        if config == nil, !FileManager.default.fileExists(atPath: url.path) { return FreespinConfig() }
        do {
            return try FreespinConfig.load(from: url)
        } catch let error as ConfigError {
            throw ConfigError(message: "\(url.path): \(error.message)")
        } catch {
            throw ConfigError(message: "\(url.path): \((error as NSError).localizedDescription)")
        }
    }
}

func daemonLog(_ line: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
    FileHandle.standardError.write("\(stamp) \(line)\n".data(using: .utf8)!)
}

func runDaemon(_ args: [String]) async throws {
    let options = try DaemonOptions(args)
    let config = try options.loadConfig()
    if options.check {
        print("\((options.config ?? DaemonOptions.defaultConfig).path): ok")
        return
    }
    // FREESPIN_INSPECT_ONLY=1 (as in the app): read devices but never divert them.
    let drive = ProcessInfo.processInfo.environment["FREESPIN_INSPECT_ONLY"] != "1"
    daemonLog("freespin daemon starting (config \((options.config ?? DaemonOptions.defaultConfig).path)\(drive ? "" : ", inspect only"))")
    // Catch signals first, so a stop while waiting for permissions or after the wheel is diverted always goes
    // through the shutdown below.
    let stopOrReload = signals([SIGTERM, SIGINT, SIGHUP])

    let store = ConfigSettingsStore(config: config)
    let manager = DeviceManager(store: store, drive: drive)
    activeManager = manager
    manager.onLog = { daemonLog($0) }
    manager.onBatteryAlert = { snapshot, alert in
        guard store.current.notifications else { return }
        notifyBattery(device: snapshot, alert: alert)
    }
    manager.onSessionsChanged = { sessions in
        let names = sessions.map(\.snapshot.name).filter { !$0.isEmpty }
        daemonLog("devices: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
    }
    if config.devices.values.contains(where: { $0.usesActionsRing }) || config.defaults.usesActionsRing {
        daemonLog("note: the Actions Ring needs the app; buttons set to actionsRing do nothing in the daemon")
    }
    // Devices are taken over once permissions are granted; a stop before that cancels the wait.
    let starting = Task {
        if drive, !(await waitForPermissions()) { return }
        do {
            try manager.start()
        } catch {
            daemonLog("cannot start: \(error)")
            exit(1)
        }
    }

    for await sig in stopOrReload {
        guard sig == SIGHUP else { break }
        await reload(options, store: store, manager: manager)
    }

    starting.cancel()
    await starting.value
    daemonLog("stopping; restoring native scrolling")
    await manager.stopAll()
}

/// Applies a reloaded config to every device. A device that rejects a write stays on its previous settings
/// and its session retries on the next apply; here it gets a few more tries before that.
private func reload(_ options: DaemonOptions, store: ConfigSettingsStore, manager: DeviceManager) async {
    do {
        store.replace(try options.loadConfig())
    } catch {
        daemonLog("reload failed, keeping the previous config: \(error)")
        return
    }
    var pending = manager.allSessions
    for attempt in 1...3 {
        var failed: [(DeviceSession, Error)] = []
        for s in pending {
            do { try await s.reapply() } catch { failed.append((s, error)) }
        }
        if failed.isEmpty {
            daemonLog("config reloaded")
            return
        }
        if attempt == 3 {
            for (s, error) in failed {
                daemonLog("reload: \(s.snapshot.name) is still on its previous settings (\(error)); "
                    + "it tries again on the next app switch, reconnect or reload")
            }
            daemonLog("config reloaded, except on \(failed.map(\.0.snapshot.name).joined(separator: ", "))")
            return
        }
        pending = failed.map(\.0)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
}

extension DeviceConfig {
    var usesActionsRing: Bool {
        (buttons ?? [:]).values.contains(.actionsRing)
            || (apps ?? [:]).values.contains { ($0.buttons ?? [:]).values.contains(.actionsRing) }
    }
}

/// Blocks until Accessibility (posting scroll and key events) and Input Monitoring (reading the mouse) are
/// granted, prompting once. Both are checked live, so granting them in System Settings needs no restart.
/// Returns false when the task is cancelled first.
private func waitForPermissions() async -> Bool {
    var prompted = false
    while !Task.isCancelled {
        let accessibility = ScrollEventPoster.hasPostPermission(prompt: !prompted)
        let input = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if !input, !prompted { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
        if accessibility, input { return true }
        if !prompted {
            let missing = [accessibility ? nil : "Accessibility", input ? nil : "Input Monitoring"].compactMap { $0 }
            daemonLog("waiting for \(missing.joined(separator: " and ")) permission for \(CommandLine.arguments[0])")
        }
        prompted = true
        do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return false }
    }
    return false
}

/// Notification Center needs an app bundle, so the daemon goes through osascript.
private func notifyBattery(device: DeviceSnapshot, alert: BatteryAlertPolicy.Alert) {
    let (title, body): (String, String) = switch alert {
    case let .low(pct): ("\(device.name) battery low", "\(pct)% remaining. Charge it soon.")
    case let .critical(pct): ("\(device.name) battery critically low", "Only \(pct)% left. Connect the charging cable.")
    }
    daemonLog("\(title): \(body)")
    func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \(quoted(body)) with title \(quoted(title))"]
    try? p.run()
}

/// Delivers `sigs` as an async sequence instead of their default actions.
func signals(_ sigs: [Int32]) -> AsyncStream<Int32> {
    AsyncStream { continuation in
        let sources = sigs.map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { continuation.yield(sig) }
            source.resume()
            return source
        }
        continuation.onTermination = { _ in sources.forEach { $0.cancel() } }
    }
}
