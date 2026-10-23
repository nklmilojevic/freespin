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
    if drive { await waitForPermissions() }

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
    // Catch signals before the wheel is diverted so a stop always gives it back.
    let stopOrReload = signals([SIGTERM, SIGINT, SIGHUP])
    try manager.start()

    for await sig in stopOrReload {
        guard sig == SIGHUP else { break }
        do {
            store.replace(try options.loadConfig())
            var failed: [String] = []
            for s in manager.allSessions {
                do {
                    try await s.reapply()
                } catch {
                    daemonLog("reload: \(s.snapshot.name) kept its previous settings: \(error)")
                    failed.append(s.snapshot.name)
                }
            }
            daemonLog(failed.isEmpty ? "config reloaded" : "config reloaded, except on \(failed.joined(separator: ", "))")
        } catch {
            daemonLog("reload failed, keeping the previous config: \(error)")
        }
    }

    daemonLog("stopping; restoring native scrolling")
    await manager.stopAll()
}

extension DeviceConfig {
    var usesActionsRing: Bool {
        (buttons ?? [:]).values.contains(.actionsRing)
            || (apps ?? [:]).values.contains { ($0.buttons ?? [:]).values.contains(.actionsRing) }
    }
}

/// Blocks until Accessibility (posting scroll and key events) and Input Monitoring (reading the mouse) are
/// granted, prompting once. Both are checked live, so granting them in System Settings needs no restart.
private func waitForPermissions() async {
    var prompted = false
    while true {
        let accessibility = ScrollEventPoster.hasPostPermission(prompt: !prompted)
        let input = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if !input, !prompted { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
        if accessibility, input { return }
        if !prompted {
            let missing = [accessibility ? nil : "Accessibility", input ? nil : "Input Monitoring"].compactMap { $0 }
            daemonLog("waiting for \(missing.joined(separator: " and ")) permission for \(CommandLine.arguments[0])")
        }
        prompted = true
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }
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
