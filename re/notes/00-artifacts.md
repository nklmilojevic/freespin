# 00 — Artifacts & extraction ("decryption")

Target: Logi Options+ 2.6.944893 (`com.logi.optionsplus`), installed 2026-09-14.

## What ships

| Component | Path | Kind | Notes |
|---|---|---|---|
| UI | `/Applications/logioptionsplus.app` | Electron (541 MB) | All UI logic in `Contents/Resources/app.asar`; JS obfuscated with javascript-obfuscator |
| Agent (the real product) | `/Library/Application Support/Logitech.localized/LogiOptionsPlus/logioptionsplus_agent.app` | Native C++/ObjC++, Qt 5.15.13, universal x86_64+arm64, 176 MB | Bundle id `com.logi.cp-dev-mgr`, Developer ID QED4VVPZWA, hardened runtime, notarized |
| Updater | `…/logioptionsplus_agent.app/Contents/Frameworks/logioptionsplus_updater.app` | native | out of scope |
| Crash handler | `…/MacOS/logi_crashpad_handler` | crashpad | drop |
| Device DB / defaults | `…/Contents/Resources/data/` → copied to `re/data/` | JSON/YAML/PNG | `options_devices.json`, `guru_devices.json`, `DeviceCompatibility.json`, `defaults/*`, `applications.json`, `strings/*.yaml` |
| Creative plugins | `/Library/Application Support/Logitech.localized/LogiOptionsPlus/{Plugins,integrations}` | Adobe CEP/UXP | out of scope |

Agent entitlements: `com.apple.developer.hid.virtual.device` (IOHIDUserDevice), apple-events automation
(scripting target Word), keychain groups. No App Sandbox.

## "Decryption" status

There is **no binary encryption** (`LC_ENCRYPTION_INFO` absent — Developer ID build, not App Store FairPlay).
The protections are:

1. **JS obfuscation** (javascript-obfuscator: rotated string array + decoder, `_0x…(0x3d1c)` lookups, control-flow flattening).
   - Undone with `webcrack@2.15.1` (string arrays decoded in isolated-vm 7.0.1; `tools/webcrack/`).
   - Output: `re/asar/deob/{main,app.min,cc.min,…}` — strings restored, identifiers still mangled.
2. **Stripped-ish native binary** — not really: 260k symbols, ~14k exported text symbols, full C++ demangling,
   ObjC class/ivar metadata intact, source paths in log strings (`/Users/admin/builds/kiros/kiros/logi/...`; internal codename **"kiros"**).
3. **Protobuf API** — schemas recovered *exactly* from embedded `FileDescriptorProto`s:
   `tools/extract_protos.py` → `re/protos/` (83 files, `logi/protocol/*.proto`, `logi/common_protocol/*.proto`).
4. Signed resources: `Excluded_Devices.json` + `.sig`, `firmware.pem`, `logitech-lap-public.pem` (signature verification of
   downloaded content; public keys only).

## Reproduce

```fish
cd ~/dev/personal/logi/re
set AG "/Library/Application Support/Logitech.localized/LogiOptionsPlus/logioptionsplus_agent.app"
lipo "$AG/Contents/MacOS/logioptionsplus_agent" -thin arm64 -output bin/logioptionsplus_agent.arm64
nm -C bin/logioptionsplus_agent.arm64 > bin/symbols.txt
uv run --script tools/extract_protos.py bin/logioptionsplus_agent.arm64 protos
bunx --bun @electron/asar extract /Applications/logioptionsplus.app/Contents/Resources/app.asar asar/extracted
tools/webcrack/node_modules/.bin/webcrack asar/extracted/app.min.js -o asar/deob/app.min -f
```

Hopper (via REA MCP, provider `hopper`) opened `bin/logioptionsplus_agent.arm64`
(sha256 `42ce41c762de554124a30d3391fa07e9053ae419469d26b0cef7a544c8db405a`).
Batch decompile of 72 scroll-pipeline ObjC methods → `decomp/scroll/*.m`
(evidence ids in file headers). `python3 -I tools/split_decomp.py <rea-json> <outdir>` splits REA batch output.

Caveat: Hopper prints doubles as raw IEEE-754 hex and occasionally mis-tracks signs — verify against `otool -tvV` assembly.

## Source tree (from embedded paths, count of distinct files)

`logi/provider/devices` (162), `logi/provider/macros` (74), `logi/gestures/osx` (68 — **scroll engine**),
`logi/util`, `logi/cp_dfu` (firmware update), `logi/provider/flow` (34), `logi/device_gestures`, `logi/highlights`
(presenter spotlight), `logi/marconi`, `logi/pipeline`, `logi/router` (IPC router), `logi/unified_profiles`,
`logi/provider/profiles_v2`, `logi/provider/accounts`, `logi/settings`, plus `thekogans/{util,crypto,stream,packet}`
(third-party C++ framework used for networking/crypto — Flow).

## Scroll-relevant ObjC classes (logi/gestures/osx)

`wheel_mouse_handler`, `wheel_hysteresis`, `wheel_disturbance_filter`, `wheel_ratchet_detect`, `hysteresis_switch`,
`gesture_scroll_helper`, `gesture_handler_2_finger_scroll` (wheel → phased/momentum scroll), `gesture_handler_*`
(swipes, zoom, rotate, pan, desktop swipe, pages swipe), `injector` + `injector_1012/1013/1300` + `injector_factory`
(CGEvent synthesis per macOS version), `IOHIDSystemUtils`, `adobe_acrobat_helper`.

Key imports: `CGEventCreateScrollWheelEvent`, `CGEventSetIntegerValueField`, `CGEventCreateFromData` (raw gesture
events), `CGEventTapCreate`, `CGEventPost/PostToPid`, `IOHIDManager*`, `IOHIDDeviceSetReport`,
`IOHIDUserDeviceCreateWithProperties`, `IOHIDPostEvent`, CoreBluetooth.
