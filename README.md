<p align="center"><img src="docs/icon.png" width="128" alt="Freespin icon"></p>

<h1 align="center">Freespin</h1>

<p align="center">A native Swift replacement for Logi Options+ on macOS, with smooth, high-resolution scrolling for Logitech mice.</p>

<p align="center"><img src="docs/screenshot.png" width="760" alt="Freespin settings window showing an MX Master 3S"></p>

## Why

Logi Options+ is a 541 MB Electron app plus a 310 MB native agent with a Qt runtime, an updater, analytics and cloud accounts, all to tune a mouse. Freespin is one 2.8 MB SwiftUI app that talks HID++ to the device directly and does its own smooth scrolling.

## Freespin vs Options+

Measured on the same Mac (macOS 27.0.1, Apple silicon) with an MX Master 3S over Bluetooth, Options+ 2.6.944893.

| | Freespin | Logi Options+ |
|---|---|---|
| Install size | **2.8 MB** (1.7 MB executable) | **851 MB** (541 MB app + 310 MB agent bundle) |
| Processes, window open | **1** | **6** (UI, GPU, renderer and utility helpers, agent, updater) |
| Memory, window open | **65 MB** | **≈ 602 MB** (renderer 240, agent 166, GPU 100, UI 51, updater 38, utility 7) |
| Memory, running in background | **45 MB** | **179 MB** (agent 143, updater 36) |
| Idle CPU, in background (30 s average) | **0.10 %** | **2.03 %** |
| Runtime | Swift, SwiftUI, IOKit, CoreGraphics | Electron (Chromium + Node), C++ agent on Qt 5.15 |
| Account, cloud, analytics | none | yes |

Memory is the physical footprint reported by `top`. Idle CPU is the process's CPU time over 30 s with nothing happening (`ps -o cputime`), with each app driving the wheel on its own.

## Features

- **Smooth, high-resolution scrolling.** The wheel is diverted to HID++ high-resolution reports (15 steps per notch on the MX Master 3S) and run through a wheel processor with period timing, hysteresis, ratchet detection, middle-click suppression and an acceleration curve. The result is posted as continuous pixel scroll events with line and fixed-point fields filled in. Recorded traces match Options+ in event structure and ≈10.3 vs 10.4 px per line.
- **Scroll speed and direction**, and native line scrolling when smooth scrolling is off (the wheel is handed back to macOS).
- **Thumb wheel** horizontal scrolling with its own speed and direction.
- **SmartShift**: on/off, sensitivity, and ratchet force on wheels that have it.
- **Pointer speed** (DPI).
- **Buttons**: remap Middle, Back, Forward, Gesture and Mode Shift to Back/Forward, Middle Click, Mission Control, App Exposé, Show Desktop, Launchpad, desktop left/right, Screenshot, Gestures or the Actions Ring.
- **Gesture button**: click, or hold and move for Mission Control, App Exposé and switching desktops. An experimental "trackpad swipes" style uses the Dock's swipe gestures instead of shortcuts.
- **Actions Ring**: hold a button and a radial menu of eight actions appears at the cursor; move toward one and release.
- **Per-app settings**: different scroll speed, smoothness, direction or buttons while a given app is frontmost.
- **Logi Bolt and Unifying receivers**: devices behind a receiver show up and disconnect live, and you can pair and unpair from the app. Bolt pairing uses the same two-button confirmation as Options+, one highlighted button at a time.
- **Flow (experimental)**: push the pointer past the screen edge facing another Mac running Freespin and the mouse switches to it (HID++ Easy-Switch), with linked Logitech keyboards and the clipboard following. It is local only: computers find each other with Bonjour and talk over an encrypted TCP connection. You pair them once by checking that both show the same six-digit code; no account or Logitech server is involved. It doesn't interoperate with Options+ Flow. So far it has been tested with simulated devices between two processes and between a Mac and a macOS VM (`freespinctl flow-sim`), not yet with a real mouse moving between two Macs.
- **Low-battery notifications** at 15 % and 5 %.
- **Keyboard**: Fn-key inversion and backlight for Logitech keyboards that support them (implemented, not yet tested on hardware).
- Runs in the background with no Dock icon. Closing the window keeps the mouse working, opening Freespin again brings the window back, and Quit (⌘Q or the gear menu) gives the wheel back to macOS. "Open at Login" starts it hidden.

Not included: Smart Actions (macros), firmware updates, accounts, analytics, webcam and presenter features.

<p align="center"><img src="docs/bolt-pairing.png" width="680" alt="Pairing an MX Master 3S with a Logi Bolt receiver"></p>

Tested on an MX Master 3S over Bluetooth and through a Logi Bolt receiver. Other HID++ 2.0 mice and Unifying receivers use the same code paths but haven't been tried yet.

## Build

Requires Xcode 16+ (Swift 6 toolchain) and macOS 14+.

```fish
swift test                                # unit tests
./scripts/build-app.sh                    # → build/Freespin.app + build/freespinctl (universal, ad-hoc signed)
SIGN_IDENTITY="Developer ID Application: …" ./scripts/build-app.sh   # stable identity keeps permissions across rebuilds
./scripts/dmg.sh                          # → dist/Freespin-<version>.dmg, freespinctl tarball, SHA256SUMS
open build/Freespin.app
```

On first launch macOS asks for **Input Monitoring** (to read the mouse) and **Accessibility** (to post scroll and key events), and Freespin asks to send notifications.

Quit Logi Options+ first; two apps driving the same wheel fight each other. To unload its background agent:

```fish
launchctl bootout gui/(id -u)/com.logi.cp-dev-mgr
# bring it back later:
launchctl bootstrap gui/(id -u) /Library/LaunchAgents/com.logi.optionsplus.plist
```

`freespinctl` is a command-line companion for inspecting and debugging devices:

```fish
swift run freespinctl list        # devices, battery, DPI
swift run freespinctl features    # HID++ feature table
swift run freespinctl controls    # divertable buttons and their reporting state
swift run freespinctl receivers   # Bolt/Unifying receivers and their devices
swift run freespinctl pair        # pair a new device to the receiver
swift run freespinctl sniff       # print HID++ notifications
swift run freespinctl trace out.jsonl   # record wheel reports and scroll events
swift run freespinctl run         # headless scroll engine
```

## Running without the app

`freespinctl daemon` does what the app does in the background, configured by a JSON file instead of the window. Use it as a LaunchAgent, for example from Nix. Don't run it alongside the app.

```json
{
  "default": { "scrollSpeed": 60, "smoothScrolling": true },
  "devices": {
    "MX Master 3S": {
      "dpi": 1600,
      "smartShift": true,
      "smartShiftSensitivity": 12,
      "buttons": { "gesture": "gestures", "back": "missionControl" },
      "apps": { "com.apple.Safari": { "scrollSpeed": 45 } }
    }
  },
  "flow": { "enabled": true, "syncClipboard": true, "linkKeyboard": true },
  "notifications": true
}
```

- Settings a file leaves out keep the value the device already has. `default` applies to every device. Entries under `devices` match a device by name, product ID (`"b034"`) or device key (`"b034-FD094774-ff"`, as `freespinctl list` shows it), and the more specific entry wins.
- Device keys: `scrollSpeed` and `thumbwheelSpeed` (0–100, 50 is the default), `smoothScrolling`, `naturalScrolling`, `thumbwheelNaturalScrolling`, `smartShift`, `smartShiftSensitivity` (1–50), `smartShiftTorque` (1–100), `dpi`, `gestureStyle` (`shortcuts` or `trackpad`), `fnKeysFirst`, `backlight`, `buttons` and `apps` (bundle ID to `scrollSpeed`, `smoothScrolling`, `naturalScrolling`, `thumbwheelSpeed`, `buttons`).
- Buttons: `middle`, `back`, `forward`, `gesture`, `modeShift`, or a control ID such as `0x00c3`. Actions: `default`, `back`, `forward`, `middleClick`, `missionControl`, `appExpose`, `showDesktop`, `launchpad`, `desktopLeft`, `desktopRight`, `screenshot`, `gestures`. The Actions Ring needs the app.
- Unknown keys and out-of-range values are errors. `freespinctl daemon --check --config <file>` validates a file. `SIGHUP` reloads it, and `SIGTERM` gives the wheel back to macOS.
- The default config is `~/.config/freespin/config.json`. Flow's identity and paired computers live in `~/Library/Application Support/Freespin/daemon`, apart from the app's.

Pair Flow computers through the running daemon:

```fish
freespinctl flow status                 # this computer and the ones it can see
freespinctl flow pair studio            # compare the six-digit code, answer y
freespinctl flow confirm                # on the other computer, when it started the pairing
freespinctl flow side studio right      # where that computer sits
```

With home-manager, the flake provides a module that installs the signed release binary, writes the config and runs the LaunchAgent. A typo in `settings` fails `home-manager switch`:

```nix
{
  inputs.freespin.url = "github:nklmilojevic/freespin";
  # in your home-manager modules:
  imports = [ inputs.freespin.homeManagerModules.default ];
  services.freespin = {
    enable = true;
    settings = {
      devices."MX Master 3S" = { dpi = 1600; buttons.gesture = "gestures"; };
      flow.enabled = true;
    };
  };
}
```

With Homebrew:

```fish
brew install --cask nklmilojevic/freespin/freespin   # the app, which updates itself
brew install nklmilojevic/freespin/freespinctl       # the CLI; `brew services start freespinctl` runs the daemon
```

The Nix agent runs a copy of the binary at `~/Library/Application Support/Freespin/bin/freespinctl`, so its Accessibility and Input Monitoring grants survive updates. On first start, grant both to that file. The daemon waits and starts once they're on. Logs go to `~/Library/Logs/freespin.log`.

## Releases and updates

The app checks for updates with [Sparkle](https://sparkle-project.org). It reads `appcast.xml` from the latest GitHub release, so nothing else is hosted. "Check for Updates…" and automatic checks are in the gear menu.

Pushing a `v*` tag makes CI sign the app, `freespinctl` and the DMG with the Developer ID, notarize them, staple the app and the DMG, and publish the DMG, the CLI tarball, `SHA256SUMS` and `appcast.xml`. It needs these repository secrets:

| Secret | What it is |
|---|---|
| `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD` | the Developer ID Application certificate and key, base64-encoded `.p12` |
| `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | an App Store Connect API key for `notarytool`, base64-encoded `.p8` |
| `SPARKLE_PRIVATE_KEY` | the EdDSA key from Sparkle's `generate_keys -x`; its public half is `SUPublicEDKey` in `scripts/build-app.sh` |

A signed, notarized build on your own Mac:

```fish
SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=<notarytool profile> ./scripts/dmg.sh
./scripts/appcast.sh <version>          # signs with the key in your login keychain
```

After a release, `scripts/update-nix-release.sh <version>` points the Nix package at it. The Homebrew tap updates itself.

## How it works

```
MX Master 3S ──HID++ 2.0 over BLE/USB/Bolt──► HIDPP (IOHIDManager)
   0x2121 hi-res wheel · 0x2150 thumb wheel · 0x1B04 buttons · 0x2111 SmartShift · 0x2201 DPI · 0x1004 battery
        │
        ▼
ScrollEngine ── WheelProcessor (timing, hysteresis, ratchet, disturbance filter, acceleration curve)
        │        ScrollInjectorModel (sub-pixel remainders, 10 px lines, 16.16 fixed point)
        ▼
EventSynth ── CGEvent scroll/key/mouse/dock-swipe synthesis
        ▲
FreespinCore ── device sessions, settings, per-app profiles, battery alerts
        ▲
FreespinApp ── SwiftUI window
```

| Package | Role |
|---|---|
| `HIDPP` | IOKit transport, HID++ framing, request/response matching, typed features |
| `ScrollEngine` | Pure-Swift wheel pipeline: timing, acceleration and scroll event modelling (no AppKit, deterministic, unit-tested) |
| `EventSynth` | Posting scroll, key and mouse events; gesture and Actions Ring logic |
| `Flow` | Freespin Flow: Bonjour discovery, Ed25519/X25519 handshake with pairing codes, ChaCha20-Poly1305 framing, edge geometry, clipboard |
| `FreespinCore` | Discovery, per-device sessions, settings store, frontmost-app tracking, Flow device adapter |
| `FreespinApp` / `freespinctl` | The app and the CLI |

No Logitech code or assets are included in this repository.

## Disclaimer

An independent project for interoperability, not affiliated with or endorsed by Logitech. "Logitech", "Logi", "Options+", "MX Master", "SmartShift" and "Flow" are trademarks of Logitech.
