# 06 - Logitech G502 X support: feasibility assessment

Date: 2026-10-23. Scope: G502 X (wired), G502 X LIGHTSPEED, G502 X PLUS. Assessment only, nothing implemented.

Legend (same as 03): **[V]** verified here (Options+ agent symbols/strings, Solaar/libratbag source fetched from GitHub, local ioreg), **[P]** public knowledge not checked against a device, **[I]** inferred, **[?]** open, needs hardware.

## Scope decision (2026-10-23)

The goal is **G502 X working in Freespin**, not G Hub parity. Tier 1 below is the plan. Tiers 2-3 (onboard-profile editing, macros, G-Shift, host mode, LIGHTSYNC) are out of scope, and so is G Hub reverse engineering. The mouse stays in onboard mode, so its firmware keeps handling the DPI buttons, sniper and tilt exactly as it does today.

Work list for "works in Freespin":

| # | Change | Effort |
|---|---|---|
| 1 | Verify discovery: wired direct on 0xFF00 at index 0xFF; LIGHTSPEED receiver via the in-progress `Receiver.swift` | S (verify) |
| 2 | Smooth scrolling through the existing 0x2121 path; tuning pass for multiplier 8 and the heavier wheel | S |
| 3 | Ratchet/free-spin sensing via 2121 event 1 (fallback: existing hysteresis heuristics) | S (verify) |
| 4 | At attach, force native lo-res when not diverting (avoid 8x scroll if Linux/G Hub left hi-res on) | S |
| 5 | Dedupe cable + receiver paths by 0x0003 unit ID | S |
| 6 | UI gating: hide SmartShift/buttons sections when the feature is absent; DPI slider (100-25600) instead of a list; note that onboard mode may reset DPI on a DPI-button press | S |
| 7 | Battery (PLUS/LIGHTSPEED): already works; wired has none | none |
| 8 | Optional: report rate (0x8060 get/set) | S |
| 9 | Optional: remap back/forward/tilt through an active event tap (no 1B04 on this mouse) | M |

About 2-3 days of work once the hardware is here. Items 1-7 are the minimum.

## TL;DR

**Overall: Medium. Basic support is small; G Hub parity is large.**

The assumption to correct first: the G502 X **does expose 0x2121 HiRes Wheel** (multiplier 8, ratchet-switch flag set, invert flag set) on both the wired and the PLUS models [V, Solaar dumps]. That means Freespin's main feature, the diverted smooth-scroll pipeline, should work with almost no new code. The G502 X has **no 0x1B04 REPROG_CONTROLS and no 0x2110 SmartShift** [V]. Buttons therefore can't be diverted the way the MX Master 3S buttons are. Anything to do with buttons, DPI stages, macros or G-Shift goes through **0x8100 Onboard Profiles** or **0x8110 Mouse Button Spy**, and that is where the work is.

- Tier 1, "works like the MX": smooth scroll, ratchet/free-spin sensing, DPI, report rate, battery. **S-M, about 2-4 days**, mostly verification on hardware.
- Tier 2, "useful G502 app": OS-level button remaps, a read-only onboard profile viewer, profile switching, basic LIGHTSYNC. **M, about 1-2 weeks.**
- Tier 3, "G Hub parity": onboard profile editor, onboard macros, G-Shift, host mode, full LIGHTSYNC. **L, several weeks**, with real risk of corrupting profiles.

## 1. Environment check (this Mac, 2026-10-23)

| Check | Result |
|---|---|
| G Hub installed (`/Applications/lghub.app`) | **No** [V]. Only `logioptionsplus.app` is in /Applications. No `lghub*` processes are running. |
| G502 X connected | **No** [V]. ioreg shows VID 0x046D devices: MX Master 3S (BLE, PID 0xB034), "USB Receiver" PID **0xC548 = Bolt**, not LIGHTSPEED. Also "Fosi Audio ZD3". |
| LIGHTSPEED receiver connected | **No** [V]. |
| `freespinctl features` | Not run. There is no G502 X to query, and the Bolt receiver is out of scope. |

Note: uncommitted work in the tree (`Sources/HIDPP/Receiver.swift`, `DeviceManager.swift`) already classifies LIGHTSPEED receiver PIDs `0xC539, 0xC53A, 0xC53F, 0xC545, 0xC547, 0xC54D` as `.lightspeed` (pairing unsupported) and handles 0x41 connect notifications. That covers most of the receiver side.

## 2. Device identity [V: libratbag `data/devices/*.device`, Solaar `docs/devices/*`]

| Model | USB PID (wired/cable) | Wireless PID (via receiver) | Receiver | libratbag quirks |
|---|---|---|---|---|
| G502 X (wired only) | `0xC099` | - | - | `INDEX_OFFSET` |
| G502 X LIGHTSPEED | `0xC098` | `0x409F` | LIGHTSPEED, likely `0xC547` [P?] | `INDEX_OFFSET` |
| G502 X PLUS | `0xC095` | `0x4099` | LIGHTSPEED, likely `0xC547` [P?] | `G502X_PLUS` (LED is in the 2nd slot), `INDEX_OFFSET` (profile index is 1-based) |

All three run HID++ 4.2 at a 1 ms (1000 Hz) report rate [V].

### 2.1 Feature tables (Solaar dumps)

| Feature | ID | G502 X wired C099 | G502 X PLUS 4099 | Freespin today |
|---|---|---|---|---|
| Root / FeatureSet / FW / Name | 0000/0001/0003/0005 | yes | yes | **have** |
| Unified battery | 1004 | - | v3 | **have** |
| Wireless device status | 1D4B | - | yes | no (not needed) |
| Config change | 0020 | yes (RESET) | yes | no |
| **HiRes wheel** | **2121** | **v1**, multiplier 8, invert + ratchet switch | **v0**, multiplier 8, invert + ratchet switch | **have (full pipeline)** |
| Adjustable DPI | 2201 | v2 (1600 at dump time) | v2 | **have** (get/set/list) |
| Report rate | 8060 | v0 | v0 | enum only, no functions |
| **Onboard profiles** | **8100** | v0, "On-Board" mode | v0, "On-Board", profile 1 | **none** |
| Mouse button spy | 8110 | v0 | v0 | none |
| RGB effects | 8071 | - | v2 | none |
| Per-key lighting v2 | 8081 | - | v2, zones A-H | none |
| Force pairing / DFU | 1500 / 00D0, 00C2 | 00C2 | 1500, 00D0 | out of scope |
| REPROG_CONTROLS_V4 | 1B04 | **absent** | **absent** | (MX button path) |
| SmartShift | 2110/2111 | **absent** (the ratchet toggle is mechanical) | **absent** | gated by `snap.has` |
| Extended DPI / ext. report rate | 2202 / 8061 | absent | absent | - |
| Surface tuning | 2240 | absent | absent | - |

There is no Solaar dump for the G502 X LIGHTSPEED (0x409F). It is assumed to be the PLUS without 8071/8081 [I, ?].

### 2.2 The Options+ agent already implements every one of these

The Options+ agent shares Logitech's `devio` library with the G-series stack. It includes full classes for the gaming features [V, `re/bin/symbols.txt`]:

| Class | Methods (V) |
|---|---|
| `Feature8100OnboardProfiles` (420 refs) | `GetOnboardProfilesInfo`, `IsOnboardMode`/`SetOnboardMode(bool)`, `GetActiveProfile`/`SetActiveProfile`, `GetActiveProfileResolution`/`SetActiveProfileResolution`, `ReadData(int,int[,uchar])`, `BeginWrite(int,int,int)`, `WriteData`, `EndWrite`, `GetCRC`, `ExecuteMacro(int,int)`, `onFeatureReport` |
| `Feature8110MouseButtonSpy` | `GetButtonCount`, `GetButtonMap`/`SetButtonMap`, `StartSpy`/`StopSpy`, `onFeatureReport` |
| `Feature8060ReportRate` | `GetReportRateList(uchar*)`, `GetReportRate`, `SetReportRate(uchar)` |
| `Feature8071RGBEffects` (504 refs) | `GetInfo`, `GetRgbClusterInfo`, `GetEffectInfo`, `SetEffectByIndex[_Async]`, `Get/SetSWControl`, `Get/SetNvConfig`, `Get/SetRgbPowerMode[Config]`, `SynchronizeEffect`, `SetMultiLedRgbClusterPattern`, `Shutdown` |
| `Feature8081PerKeyLighting` (2115 refs), `Feature8070ColorLEDEffects` | per-zone / per-key set and commit |
| `Feature2201AdjustableDPI` | `GetSensorCount`, `GetSensorDPI`, `GetSensorDPIList`, `GetDefaultDPI`, `SetSensorDPI`, `SetSensorDPIwithClamping` |
| `Feature2240SurfaceTuning`, `Feature2202…`, `Feature8061…`, `Feature8090ModeStatus`, `Feature8111LatencyMonitoring` | present (not needed for G502 X) |

The agent also has router paths `/onboard_profiles/%s/{onboard_mode,active_profile,profiles,profile,edit_profile,enable_profile,disable_profile,restore_default_profile,restore_defaults}` [V, strings]. `protos/logi/protocol/onboard_profiles.proto` gives the profile model: up to 5 slots + 5 ROM slots, each with `report_rate`, `dpi_table`, `angle_snapping`, `lighting`, `button_mappings`, `gshift_mappings`; `OnboardMode {HOST, ONBOARD; is_temporary}`. `devices.proto` has `onboard_profile_capabilities` and `GShift`.

**Consequence:** the byte layouts can be decompiled from the binary we already have (Hopper session on `bin/logioptionsplus_agent.arm64`), and checked against libratbag's `hidpp20.c` profile parser. **G Hub reverse engineering is not on the critical path** for the protocol (see section 6).

## 3. Onboard mode vs host mode

| | Onboard mode (factory default, what Solaar saw) | Host mode (`8100 SetOnboardMode(host)`) |
|---|---|---|
| Who owns buttons | Firmware, from the active profile in flash: buttons 4/5 = back/forward, G7/G8 = DPI up/down, G9/sniper = DPI shift, tilt = horizontal scroll [P] | Host software. G Hub's mechanism is most likely 8110 spy + `SetButtonMap` [I] |
| DPI | Profile DPI stages (up to 5 + shift DPI). Host `2201 SetSensorDPI` probably lasts only until the next DPI button press or profile change [P/?] | Host sets it, and must implement DPI cycling and shift itself |
| Report rate | From the profile. Solaar notes report rate changes may need onboard profiles disabled [P] | Host sets via 8060 |
| Lighting (PLUS) | Profile effect | Host via 8071/8081 `SetSWControl` |
| Wheel (2121) | Diversion is independent of profile mode [I, ?] | same |
| Without software | Fully functional | Degraded (DPI buttons do nothing, etc.) until power cycle [?] |

**Recommendation:** stay in **onboard mode** by default. Do the convenience features host-side, on top of what the OS already sees, and only *edit* profiles when the user explicitly opts in. Host mode means Freespin must reimplement firmware behaviour, and if the app crashes the mouse is left degraded.

## 4. G Hub feature inventory vs what Freespin would need

| G Hub feature | Mechanism on G502 X | Freespin status | Effort |
|---|---|---|---|
| DPI stages (5) + indicator LEDs | 8100 profile `dpi_table` | none | M (needs profile write) |
| DPI shift / sniper | Onboard: firmware. Host: 2201 set on press/release | firmware does it already | S (onboard) / M (host) |
| Report rate 125-1000 Hz | 8060 or profile | enum only | S |
| Button assignments | Profile `button_mappings` (onboard) or 8110 (host) | MX path (1B04) doesn't apply | M-L (see 5.3) |
| G-Shift layer | Profile `gshift_mappings`, or a host-side modifier layer | none | M (host layer once buttons can be captured) / L (onboard) |
| Macros | Onboard macro memory (`ExecuteMacro`, profile macro blobs) or host-synthesized | `ActionPerformer` can synthesize keys | M (host) / L (onboard) |
| Per-game / per-app profiles | Host: switch on frontmost app; or `SetActiveProfile` | **have** per-bundle `AppOverride` + `FrontmostAppMonitor` | S-M (extend overrides to DPI/rate/lighting/profile slot) |
| LIGHTSYNC (PLUS) | 8071 effects, 8081 per-zone, `SetSWControl` | none | M (static/breathing/off) / L (animated, audio, screen sampler) |
| Surface tuning | 0x2240 not exposed on G502 X [V, Solaar] | - | N/A unless hardware shows otherwise [?] |
| Onboard memory toggle | 8100 `SetOnboardMode` | none | S (but see section 3) |
| Lua scripting, Discord/OBS integrations | G Hub app features | - | out of scope |
| Firmware update | 00C2 / 00D0 DFU | - | out of scope, leave to Logitech |

## 5. Mapping onto Freespin, piece by piece

| # | Piece | What exists | Gap | Effort |
|---|---|---|---|---|
| 1 | Wired transport (C099/C098/C095) | `HIDManager` matches VID 0x046D, page 0xFF00/0xFF43. `isDirectProduct` treats non-"receiver" names as index 0xFF | Verify the HID++ interface is on 0xFF00 and that a non-exclusive open works | S (verify) |
| 2 | LIGHTSPEED receiver (C547) | Uncommitted `Receiver.swift`: `.lightspeed` kind, 0x41 connect/disconnect, notification enable | Verify the slot index (likely 1; C547 holds 2 devices) and sleep/wake re-probe. Pairing (0x0309 / receiver regs) not needed: devices ship paired | S |
| 3 | Dual path (PLUS/LIGHTSPEED charging on cable shows on receiver **and** USB) | Sessions keyed `pid:location:serial:index` | Dedupe by 0x0003 unit ID (`C6884511`, `42004C00` style) and prefer one path, or the wheel gets diverted twice and events doubled | S-M |
| 4 | **Smooth scrolling** | Full 2121 pipeline: `WheelCapability`, `setWheelMode`, `WheelEvent` decode, `WheelProcessor` (hysteresis, disturbance, acceleration), `ScrollInjectorModel`, `ScrollEventPoster` | Tune for multiplier 8 and the G502 X's ratchets per rotation/diameter (read from capability). Verify diverted reports in free-spin at high speed (period count, Int16 deltas) | **S** |
| 5 | Ratchet / free-spin sensing | `WheelEvent.ratchetSwitch` → `processor.settings.freewheel` | Verify the mechanical toggle actually emits 2121 event 1 (capability flag says it can; Solaar reads state "Normal wheel mode") | S (verify) |
| 6 | SmartShift UI | Gated by `snap.has(.smartShift)` | Hide the section cleanly; show a read-only ratchet/free-spin indicator instead | S |
| 7 | DPI | 2201 get/set/list incl. `0xE000\|step` range decode | G502 X list is ~100-25600 in steps of 50 [P], about 500 values: a picker won't work, use a slider. In onboard mode a set is temporary | S |
| 8 | Report rate | `FeatureID.reportRate` only | 8060 fn0 list (bitmask), fn1 get, fn2 set [P; confirm in `Feature8060ReportRate`]. Writes may need host mode | S |
| 9 | Battery | 1004 + polling | Wired C099 has none (`battery` stays nil, fine) | none |
| 10 | Per-app overrides | `AppOverride` (speed, smooth, natural, buttons) | Add DPI / report rate / onboard slot / lighting fields. Games: default to **native wheel** (see risks) | S-M |
| 11 | Buttons, option A: event tap | `ActionPerformer`, `ButtonAction`; listen-only tap exists in `Trace.swift` | Active `CGEventTap` on `otherMouseDown/Up` (buttons 3/4 and tilt), swallow and perform. Firmware keeps G7/G8/G9 | M |
| 12 | Buttons, option B: onboard remap | none | Rewrite profile so G7/G8/G9 emit distinct mouse buttons or F13-F24, then use option A. Needs 13 | L (with 13) |
| 13 | Onboard profiles 8100 | none | Read: `GetOnboardProfilesInfo`, sector `ReadData` (16 B chunks), CRC-CCITT. Write: `BeginWrite`/`WriteData`/`EndWrite`. Profile layout per libratbag + agent decomp, quirks `INDEX_OFFSET`, `G502X_PLUS`. Backup/restore of every sector | **L** (read-only viewer + `SetActiveProfile`: M) |
| 14 | Host mode + 8110 spy | none | Decompile `Feature8110MouseButtonSpy::onFeatureReport`/`SetButtonMap`. Then reimplement DPI cycling/shift host-side | M-L |
| 15 | Gesture button / Actions Ring | Needs 1B04 rawXY on the MX | Event tap on `mouseMoved` while the trigger is held (swallow movement, feed `GestureTracker`/`RingSelector`) | M |
| 16 | LIGHTSYNC (PLUS) | none | 8071 `GetInfo`/`GetRgbClusterInfo`/`SetEffectByIndex` + `SetSWControl`, power mode. 8081 for 8 zones | M (basic) / L (animated) |
| 17 | Host macros | `ActionPerformer` keystrokes | Recorder + sequence editor UI | M |
| 18 | Coexistence with G Hub | none | Detect `lghub_agent` running and refuse to drive (both would fight over diversion and mode) | S |
| 19 | Device DB / naming | name from 0x0005 | PID table for images/labels | S |

### 5.1 Smooth scrolling without hi-res diversion (fallback only)

This isn't needed for the G502 X (2121 is present). It is worth keeping as a fallback, because diversion could misbehave in onboard mode, and for non-HID++ mice:

- Approach: active `CGEventTap` on `scrollWheel` events. Swallow events where `scrollWheelEventIsContinuous == 0`, then feed `lineDelta * N` (or `FixedPtDeltaAxis1`) into `WheelProcessor.process(periods:deltaV:…)` as synthetic notches, and post through the existing injector. This is what Mos/LinearMouse/SmoothScroll do.
- Feasibility: **M**. The engine is input-agnostic: `WheelProcessor` takes periods/deltas plus a timestamp.
- Limits: (a) **No device attribution**: a CGEvent doesn't say which mouse it came from. Correlating needs an `IOHIDManager` input-value callback on the G502's Generic Desktop/Wheel usage (0x01/0x38) plus timestamp matching. (b) **Resolution**: only whole notches (or macOS's own acceleration-distorted values), so the hysteresis and free-spin detection quality drops. (c) If the native hi-res flag is left on (Linux and G Hub turn it on, and Solaar's C099 dump shows "High resolution mode"), macOS may get 8x deltas [?]. Freespin should force `highResolution=false` whenever it isn't diverting, at attach too, not only in `stop()`.

## 6. G Hub: inventory and how to reverse engineer it (not installed, all [P] until installed)

| Component | Expected | Notes |
|---|---|---|
| UI | `/Applications/lghub.app`, Electron, `app.asar` | process `lghub` |
| Agent | native C++ (Qt), shipped in the app bundle, e.g. `…/Contents/Frameworks/lghub_agent.app` | process `lghub_agent`: device I/O, profiles, Lua engine |
| Updater | `lghub_updater.app`, launchd daemon | process `lghub_updater` |
| Data | `~/Library/Application Support/lghub/settings.db` (SQLite holding a JSON blob of all profiles/assignments). Depots (per-device manifests, images, firmware) under `/Users/Shared/LGHUB/` | the depot device manifests are the most useful artifact: button names, DPI ranges, lighting zones |
| IPC | UI ↔ agent over a local WebSocket (community projects use port 9010, JSON GET/SET/SUBSCRIBE on paths like `/devices/list`) | could be used directly for live comparisons |

Same playbook as `00-artifacts.md`:

```fish
# after installing G Hub from logitechg.com (decide first: it installs a daemon and will fight Freespin)
set GH /Applications/lghub.app
find $GH -maxdepth 4 -name "*.app" -o -maxdepth 4 -name "*.asar"
lipo <agent-binary> -thin arm64 -output re/bin/lghub_agent.arm64
nm -C re/bin/lghub_agent.arm64 > re/bin/lghub_symbols.txt
grep -c "devio::Feature8100OnboardProfiles" re/bin/lghub_symbols.txt   # shared devio? then diff with Options+
uv run --script re/tools/extract_protos.py re/bin/lghub_agent.arm64 re/protos-ghub
bunx --bun @electron/asar extract $GH/Contents/Resources/app.asar re/asar-ghub/extracted
```

The most useful **runtime** technique: macOS delivers HID input reports to every client that has the device open, so while G Hub drives the mouse a raw sniffer sees **all of G Hub's responses** (with its software IDs). The requests can be inferred from feature index and function [I, verify]. `freespinctl sniff` currently prints only notifications (swid 0); it would need a raw "print every report" mode. For full request/response capture: Windows G Hub + USBPcap/Wireshark, or Linux usbmon.

**When G Hub RE is actually needed:** host-mode button semantics (8110), LIGHTSYNC effect parameter meaning, per-device manifests (button IDs ↔ physical buttons), and the exact profile defaults. **Not needed** for 2121/2201/8060/8100 framing: the Options+ agent + libratbag cover those. Effort: S (inventory, about 1 day with the existing tooling), M if decompiling the 8110/host-mode logic.

## 7. Risks

1. **Profile writes** (8100): a wrong layout or CRC disables the profile or bricks the config, not the device. The firmware falls back to the ROM profiles, which can be restored via `restore_defaults`-style flows [P]. Mitigations: read-only dump first, keep a full sector backup per device before any write, verify CRC readback.
2. **Host mode left on** after a crash: DPI buttons dead and profile LEDs off until power cycle [?]. Mitigation: avoid host mode, or mark it temporary (`OnboardMode.is_temporary` exists in the proto) and restore on exit.
3. **Games read raw HID / GameController (GCMouse), not CGEvents.** A diverted wheel *disappears* for them, and event-tap remaps are invisible to them. Mitigation: per-app "native" mode, with games defaulting to it.
4. **G Hub coexistence**: both apps divert the wheel and switch modes. Detect and back off.
5. **Dual connection** (cable + receiver) → duplicate sessions, double scroll.
6. **Onboard mode overrides host DPI/report rate.** Users would see settings "not stick". The UI must say which mode is active.
7. **Ratchet event may not fire** for the mechanical toggle. Then free-spin detection falls back to the velocity heuristics already in `WheelHysteresis`.
8. **Different wheel physics** (heavier metal wheel, multiplier 8, long free-spin): inertia/hysteresis constants were tuned on the MX Master 3S. Expect a tuning pass with `freespinctl trace` golden traces.
9. **Wired model has no lighting and no battery**; PLUS has both. The UI must be fully feature-gated (mostly is already).

## 8. Recommended order

1. **Read-only bring-up on hardware** (`list`, `features`, `wheel` only): confirm PIDs, feature table, 2121 capability. *No writes.*
2. Small read-only additions: 8060 get/list, 8100 `GetOnboardProfilesInfo` + `IsOnboardMode` + `GetActiveProfile`, raw sector dump to a file, raw `sniff`. Decompile `Feature8100OnboardProfiles` and `Feature8060ReportRate` in Hopper to pin function numbers.
3. Identity plumbing: PID table, unit-ID dedupe of dual paths, G Hub detection, force native lo-res when not diverting.
4. **Smooth scrolling on the G502 X** via the existing 2121 path, plus ratchet sensing, a tuning pass, and per-app native mode for games. This is the core value; Tier 1 ends here (with DPI slider + report rate).
5. Event-tap button remapping for the buttons the OS sees, plus gesture/ring via movement capture.
6. Onboard profile **viewer** + `SetActiveProfile` per app (non-destructive).
7. Onboard profile **editor** (DPI stages, report rate, button map, G-Shift), with backup/restore. Tier 3.
8. LIGHTSYNC basic (PLUS), then the rest only on demand. Host mode + 8110 last, if ever.

## 9. Needs the hardware to verify

| # | Question | How (read-only unless noted) |
|---|---|---|
| 1 | Actual PIDs/WPIDs and receiver PID for the user's unit | `ioreg`, `freespinctl list` |
| 2 | HID++ interface page (0xFF00) opens non-exclusively, mouse keeps working | `freespinctl list` |
| 3 | Feature table vs Solaar (firmware may differ) | `freespinctl features` |
| 4 | 2121 capability (multiplier, ratchets/rotation, diameter, flags) and current mode (is hi-res native on?) | `freespinctl wheel` |
| 5 | Diversion works in onboard mode; ratchet event fires on the mechanical toggle; report behaviour in long free-spin | needs a write (`run`), user-approved |
| 6 | `2201 SetSensorDPI` persistence in onboard mode | write, user-approved |
| 7 | `8060 SetReportRate` accepted in onboard mode or errors | write, user-approved |
| 8 | 8100 info: memory model, profile format, sector size/count, active profile; full sector dump parses with the libratbag layout | read-only (new command) |
| 9 | 8110 spy report format | needs `StartSpy` (write), user-approved |
| 10 | Cable + receiver simultaneously: both paths present? same unit ID? | `freespinctl list` with cable in |
| 11 | LIGHTSPEED sleep/wake → 0x41 events, re-attach | watch app log |
| 12 | (PLUS) 8071 zones/effects, `GetSWControl` state | read-only |

## Sources

- Solaar `docs/devices/G502 X C099.txt`, `G502 X PLUS 4099.txt`, `Lightspeed Receiver C547.txt` (fetched via `gh api`, copies in the session scratchpad).
- libratbag `data/devices/logitech-g502-x.device`, `logitech-g502-x-wireless.device`, `logitech-g502-x-plus.device`.
- `re/bin/symbols.txt`, agent strings, `re/protos/logi/protocol/{onboard_profiles,devices,mouse}.proto`, `re/notes/03-device-layer.md`.
- Freespin sources: `Sources/HIDPP/{Features,HIDTransport,HIDPPDevice,Receiver}.swift`, `Sources/FreespinCore/{DeviceManager,DeviceSession,DeviceSettings}.swift`, `Sources/ScrollEngine/WheelProcessor.swift`.
