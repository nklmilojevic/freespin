# 03 - Device communication layer (Logi Options+ agent 2.6.944893, arm64)

Legend: **[V]** verified in binary (symbol, string, or decompiled/disassembled code), **[P]** public HID++ knowledge (Solaar/libratbag) not checked in this binary, **[I]** inferred from names, **[?]** open.

Sources: `bin/symbols.txt` (nm -C), `bin/logioptionsplus_agent.arm64` strings, `protos/`, `data/`. Hopper was shut down before the devio pseudocode could be dumped, so no devio function body beyond the scroll entry points was read. Disassembly was produced with `otool -tV` into the scratchpad.

## 1. Transport and object model

### 1.1 Classes [V, from symbols]
- Interfaces: `devio::IIDevice`, `IIHardwareDevice`, `IIHardwareBus`, `IIReceiver`, `IIDeviceManager`, `IIAccessoryBus`, `IIBluetoothBus/Device`, `IITimer`. Concrete: `devio::Device` (core HID++ state machine), `DeviceManager`, `MacOSBus`, `MacOSDevice`, `UnifyingBus`, `UnifyingDevice`, `BleppBus`, `BleppDevice`, `BtSerialBus`, `BtSerialDevice`, `CenturionTransport`, `CenturionPacketLayer`, `CenturionDevice`, `CombinerBus`, `CombinerDevice`, `AdapterDevice`, `AccessoryBus/Device`, `PairingBus/Device`, `ReceiverStub`, `HPP10Command`, `BtUnpairDetector`.
- Async: `devio::future`, `shared_future`, `promise`, `future_shared_state`, `continuable`, `make_ready_future`, `make_exceptional_future`, `get_and_catch`.
- Pub/sub: `devio::Producer<T>` / `devio::Subscriber` with `manual_subscribe(T*, safe_executor)`, `unsubscribe_all`, `subscriptions_total`, `produce(std::function<void(T*)>)`. Producers exist for `IIHardwareBus::PlugUnplug`, `IIReceiver::BleProDiscovery`, `BleProPairing`, `DfuControlTimeout`, `LockingChange`, `RegisterZeroOverwritten`, `IIDevice::{Connect, CommandMonitor, WriteReport}`, `IIFeature2121HiResWheel::{Report, RatchetSwitch}`, `IIFeature2130RatchetWheel::Report`.
- Requests: `devio::DeviceRequest` (methods include `command()`, `command_payload()`, `response_payload()`, `next_command_packet()`, `more_to_send()`, `window_count()`, `set_device_interface(DeviceInterface, unsigned, unsigned)`, `set_swid()`, `set_as_original_cmd()`, `set_cached(Cached)`, `set_error()`, `capture_error()`, `complete()`, `response(unsigned)`, `priority()`, `cancel()`). `devio::RequestOptions` (143 symbols), `devio::ProtocolType`, `devio::DeviceInterface` (1315 refs), `devio::FeatureProtocol` (4887 refs; the protocol selector used by `feature_by_id`, `feature_by_index`, `feature_count`, `probe_protocol`).
- `devio::Cached` (1651 refs): a flag on requests and feature loads. `Device::load_feature(int, Cached, FeatureProtocol)`.
- `devio::HybridReporting`: appears in 60 symbols; purpose [?].

### 1.2 Discovery and open [V for names, [?] for matching values]
- macOS HID path: `devio::MacOSBus` wraps IOHIDManager. Functions: `createMatchingDict(unsigned)`, `createMatchingDictArray()`, `createMatchingDictEntry(unsigned, unsigned)`, `deviceMatchingCallback`, `deviceRemovalCallback`, `deviceEnumeratedCallback`, `deviceReEnumeratedCallback`, `onDeviceAdded/Removed/Enumerated/ReEnumerated`, `isDevice(IOHIDManager*)`, `knownDevice`, `lookupPid/cachePid/savePidCache` (a PID cache on disk), `registerForSystemPower` / `onMySleepCallBack` (sleep/wake re-enumeration), `startBluetoothMonitor/stopBluetoothMonitor/refreshBTDevices`. IOHID imports used: IOHIDManagerCreate, SetDeviceMatching(Multiple), RegisterDeviceMatchingCallback, RegisterDeviceRemovalCallback, ScheduleWithRunLoop, IOHIDDeviceOpen, IOHIDDeviceRegisterInputReportCallback, IOHIDDeviceSetReport(WithCallback), IOHIDDeviceGetProperty, IOHIDElement*.
- [resolved, round 2] Vendor ID 0x046D and usage pages 0xFF00 (usage 2) and 0xFF43 (usage 0) are in `MacOSBus::createMatchingDict` (section 11.7).
- Bluetooth LE path: `devio::BleppBus` uses CoreBluetooth. Methods: `ble_start_scan/stop_scan`, `on_device_discover`, `on_device_connect`, `on_device_fail_to_connect`, `on_device_disconnect`, `on_device_pnp_id(NSData)`, `on_device_serial(NSString)`, `on_device_blepp(CBPeripheral, CBCharacteristic)`, `on_device_did_write`, `on_report(CBPeripheral, NSData)`, `ble_monitor_report(unsigned, vector<Byte>, bool)`, `complete_peripheral`, `detect_unpairings(_after_delay)`, `is_paired_device_with_name`. [V] BLE is called "blepp" in the code. [resolved, round 2] Logitech base-UUID services/characteristics `00010000`/`00010001` and `00050000`/`00050001` (suffix `-011F2000046D`), section 11.2.
- Classic Bluetooth serial: `BtSerialDevice` on IOBluetooth RFCOMM (`start_rfcomm`, `rfcommChannelData`, `rfcommChannelWriteComplete`, `onBTConnected`, `onBTDisconnected`, `deviceThread`, `onPayload`, `processRead`, `commandTimeoutInMs`, `lastResponseTimeMs`, `verify_connection_following_timeout`).
- Centurion (CentPP) packet layer: `CenturionPacketLayer::write/onRead` and `CenturionTransport`. Feature IDs 0000/0001/0003 have Centurion variants (`IFeature0000CenturionRoot`, `0001CenturionFeatureSet`, `0003CentPPBridge`). [V] Centurion is a separate framing from HID++ 2.0 that wraps it.
- Receivers: `UnifyingBus` (Unifying and Bolt/Lightspeed receivers; methods such as `enumerate_devices_attempt`, `perform_connect(int)`, `perform_disconnect`, `paired_devices`, `get_pairing_info`, `unpair`, `read_fw_info`, `read_unique_identifier_async`, `enable_register_zero_monitoring`, `onRegisterZeroOverwritten`). Pairing PIDs go through `HPP10Command`.
- HID++ 1.0 commands via `devio::HPP10Command` (2693 symbols): `read_receiver_connection_state`, `read_receiver_firmware_info_async`, `read_pairing_info`, `get_activity`, `open_lock/close_lock`, `enter_dfu`, `read_dfu_control`, `mdf_enable/disable_features`, `mdf_get_info`, `ble_pro_pair`, `ble_pro_unpair`, `ble_pro_perform_discovery`, `ble_pro_read_discovery_status`, `ble_pro_read_pairing_info`, `ble_pro_cancel_pairing`.
- Report IDs 0x10 / 0x11 / 0x12 (short / long / very long) [P, unverified]. Round 2: function responses are padded to 16 bytes, which matches the HID++ long parameter size (section 11.1). Strings for these were not identified. Confirm by looking at the `feature_payload_per_packet(DeviceInterface)` callers (see 1.4).

### 1.3 Framing and matching [partly V]
- `Device::feature_payload_per_packet(DeviceInterface)` and `Device::feature_protocol_on_interface(DeviceInterface)` [V] show payload size depends on the interface (short/long/very-long). Exact bytes [P]: short 7 bytes, long 20, very long 64. Feature index in byte 1 and function/SW ID in byte 3 low nibble [P].
- Software ID: `DeviceManager::swid()/set_swid`, `Device::swid()/swid_with_update()`, `DeviceRequest::set_swid`. Exception `DevioExceptionSwidConflict` [V]. Public convention: SWID 1..15, echoed in the response low nibble [P].
- Timeouts and retries: `Device::set_command_timeout(unsigned)`, `set_retries(unsigned, unsigned, unsigned)`, per-bus `commandTimeoutInMs()`. Exceptions: `WriteTimeout`, `NoResponse`, `UnexpectedResponse`, `RequestCancelled`, `RequestAlreadyContinued`, `UnifyingMaxRetryAttempts`, `PingDidNotMatch`, `SpuriousWriteError`, `CommandResponseTooShort`, `CommandResponseInvalid` [V]. Numeric defaults [?].
- Error codes [V, names]:
  - HID++ 2.0: NoError, Unknown, UnknownError, InvalidArgument, OutOfRange, HwError, NotAllowed, InvalidFunctionId, InvalidFeatureIndex, Busy, Unsupported. Public numbering: 0x00 NoError, 0x01 Unknown, 0x02 InvalidArgument, 0x03 OutOfRange, 0x04 HWError, 0x05 LogitechInternal, 0x06 InvalidFeatureIndex, 0x07 InvalidFunction, 0x08 Busy, 0x09 Unsupported [P, values unverified].
  - HID++ 1.0: Success, UnknownDevice, TooManyDevices, ResourceError, RequestUnavailable, InvalidSubid, InvalidAddress, InvalidValue, InvalidParamValue, ConnectFail, AlreadyExists, WrongPinCode, Busy, UnknownError [V, names].
- Notification dispatch: `Device::onCommandFailed(ErrorCode, unsigned)`, `onTimerEvent`, `onWirelessStatusEvent(bool,bool,bool)`, `onPowerChange`, `onActiveChanged`, `onFastDisconnect`, `onAccessDenied/Restored`. Feature events are routed through feature Report producers.
- Feature discovery: `Device::load_feature_root`, `load_feature_at_index`, `load_feature(int, Cached, FeatureProtocol)`, `feature_count`, `features_found`. Feature index comes from the root feature (0x0000 `getFeature`) and the FeatureSet (0x0001 `getFeatureID`/`getCount`) [P for the function layout].

### 1.4 Open items for transport
- [?] Where `feature_payload_per_packet` picks short/long/very-long (round 2: runtime map, section 11.8), and the report-ID byte values.
- [resolved] `BleppBus` GATT UUIDs: section 11.2.
- [resolved] IOHID matching values: section 11.7.
- [?] Concrete timeout and retry numbers.

## 2. HID++ 2.0 feature catalog

Class names are verified [V]. Feature IDs are from `IIFeature<ID><Name>` / `Feature<ID><Name>` class names [V]. Byte layouts are [P] unless noted.

| Feature ID | Class (V) | Role | Notes |
|---|---|---|---|
| 0x0000 | Feature0000Root / IFeature0000Root | IRoot | getFeature, ping |
| 0x0001 | Feature0001FeatureSet / IFeature0001FeatureSet | FeatureSet | count, getFeatureID |
| 0x0003 | Feature0003FirmwareInfo / IFeature0003FirmwareInfo (5862 refs) | FW info | entity count and per-entity versions |
| 0x0005 | Feature0005DeviceNameType (symbol `DeviceNameType`) | name, type | |
| 0x0100 | Feature0100DeviceInfo | Device info | [I] Not standard HID++ 2.0 numbering. Likely a Logitech-specific or Centurion ID. Verify. |
| 0x0101 | Feature0101DeviceName | Device name | [I] same caveat as 0x0100 |
| 0x0102 | Feature0102Root / Feature0000Root (Centurion root) | Root (alt) | [I] appears to be the Centurion/CentPP root |
| 0x0103 | Feature0103FeatureSet, Feature0103Memfault | FeatureSet (alt) / Memfault | [I] |
| 0x0305 | Feature0305BtHostInfo | BT host info | [V] name |
| 0x0309 | Feature0309LightSpeedPairing | LightSpeed pairing | [V] name |
| 0x0700 | Feature0700FitsMolding | FITS molding | [V] name |
| 0x0701 | Feature0701TWBudsTapControl | Buds tap control | [V] name |
| 0x0000..0x0003 CentPP | Feature0003CentPPBridge | CentPP bridge | |
| 0x1000 | BatteryUnifiedLevelStatus | battery (legacy) | [P] |
| 0x1004 | IIFeature1004UnifiedBattery (514 refs) | unified battery | [P] |
| 0x1500 | Feature1500ForcePairing | force pairing | [V] name |
| 0x1701 | Feature1701UserActivityMonitoring | activity monitor | [V] name |
| 0x1814 | IIFeature1814ChangeHost (434 refs) | Easy-Switch host change | [P] |
| 0x1815 | HostsInfos | host info | [P] |
| 0x1816 | Feature1816BleProPrepairing | BLE Pro prepairing | [V] name |
| 0x1982 | Feature1982Backlight | backlight | [P] |
| 0x1983 | KeyboardBacklight | keyboard backlight | [P] |
| 0x1990 | IIFeature1990IlluminationLight | illumination light | [V] name |
| 0x19B0 | Feature19B0HapticFeedback (942 refs) | haptics | [V] name |
| 0x19C0 | Feature19C0ForceSensingButton | force-sensing button | [V] name |
| 0x1A01 | IIFeature1A013DSensor | 3D sensor | [V] name |
| 0x1B03 | Feature1B03SpecialKeys | legacy special keys | [V] name |
| 0x1B04 | Feature1B04SpecialKeys (830 refs) | REPROG_CONTROLS_V4 | section 6 |
| 0x1BC0 | Feature1BC0ReportHIDUsages | report HID usages | [V] name |
| 0x2110 | Feature2110SmartShift | SmartShift | section 4 |
| 0x2111 | Feature2111SmartShiftWithTunableTorque | SmartShift + torque | [V] name |
| 0x2121 | Feature2121HiResWheel (659 refs) | HiRes wheel | section 3 |
| 0x2130 | Feature2130RatchetWheel | ratchet wheel | section 3 |
| 0x2150 | Feature2150Thumbwheel | thumbwheel | section 3 |
| 0x2201 | Feature2201AdjustableDPI | DPI | [P] |
| 0x2202 | IIFeature2202ExtendedAdjustableDPI (340 refs) | extended DPI | [P] |
| 0x2205 | Feature2205PointerMotionScaling | pointer motion scaling | [P] |
| 0x2230 | Feature2230AngleSnapping | angle snapping | [P] |
| 0x4303 | Feature4303LuxReport | lux report | [V] name |
| 0x4531 | Feature4531MultiPlatform | multi-platform | [P] |
| 0x4600 | IIFeature4600Crown | crown | section 6 (ratchet + divert) |
| 0x4610 | Feature4610MultiRoller | multi-roller | [V] name |
| 0x40A0 / 0x40A2 / 0x40A3 | IFeature40A0/40A2/40A3FnInversion | Fn inversion | [P] |
| 0x6100 | IIFeature6100TouchPadRawXY | touchpad raw XY | [V] name |
| 0x6501 | Feature6501Gestures (IIFeature6501Gestures: 1337 symbol refs) | gestures | section 6 |
| 0x80A3 / 0x80A4 | Feature80A3LegacyAxisResponseCurve / Feature80A4AxisResponseCurve | axis response | [V] name |
| 0x8060 | Feature8060ReportRate | report rate | [P] |
| 0x8061 | Feature8061ExtendedAdjustableReportRate | extended report rate | [P] |
| 0x8080 / 0x8081 | Feature8080PerKeyLighting / 8081 | per-key lighting | [V] name |
| 0x8088 | Feature8088MultiLightbar | multi lightbar | [V] name |
| 0x8120 | IIFeature8120GamingAttachments | gaming attachments | [V] name |
| 0x00D0 / 0x00D1 | Feature00d0DFU / 00d1ResumableDFU | DFU | [V] name |

The feature names in the class table are the Solaar/libratbag names where they match. The Centurion-style 0x0100..0x0103 IDs are the main discrepancy. Verify before relying on them.

## 3. Smooth scrolling and wheel diversion

### 3.1 Verified structure
- `logi::devices::devio_feature_2121_gesture` (the HiRes wheel handler) and `devio_feature_x2121_gesture` (a second copy with the same methods) [V]. Also `devio_feature_scroll_wheel`, `devio_feature_smartshift`, `devio_feature_2130` / `devio_feature_x2130`, and `gesture_handler` base (`_is_smooth_cached()`, `_get_speed_cached()`, `_device_id()`) [V].
- Methods (V): `_set_mode(mode const&)`, `_get_mode(bool)`, `_get_capabilities(bool)`, `_set_parameters(bool, bool)`, `_cache_resolution(bool)`, `_is_inverted(bool)`, `is_invertable()`, `supports_high_resolution()`, `onSettingChange(unsigned, bool, bool, bool, unsigned, unsigned, bool)`, `onWheelMovement(bool, unsigned, int, int)`, `onRatchetSwitch(bool)`, `broadcast_ratchet_change(bool)`, `_accessibility_granted()`.
- Log formats [V, from strings], which show what the agent sends and receives:
  - `feature_2121 %s _set_parameters(diverted=%d, inverted=%d, _is_smooth_cached()=%d)`
  - `feature_2121 %s SetWheelMode diverted=%d high_resolution=%d inverted=%d priority=%d rate=%d analytics=%d`
  - `feature_2121 %s GetWheelMode got diverted=... high_resolution=... inverted=... priority=... rate=... analytics=...`
  - `feature_2121 %s GetWheelCapability got multiplier=%u has_proirity has_rate has_ratchet_switch has_inversion`
  - `feature_2121 %s GetWheelCapability got has_analytics_data ratchets_Per_rotation wheel_diameter`
  - `feature_2121 %s onWheelMovement(high_resolution=%d, period=%d, deltaV=%d, deltaH=%d)`
  - `feature_2121 %s onRatchetSwitch(ratchet=%d)`, `onSettingsChange(swid,diverted,invert,priority,rate,analytics)`
  - `feature_x2121 ...` is the same set.
  - `devio_feature_x2121_gesture::apply_configuration - speed: %f, direction: %s, smooth scrolling: %s` [V].
- Devio API (V): `Feature2121HiResWheel::{GetWheelCapability(uint*, bool*x5, uint*, uint*), GetWheelMode(bool*, bool*, bool*, uint*, uint*, bool*), SetWheelMode(bool, bool, bool, uint, uint, bool, ...), GetRatchetSwitchState(bool*), Reset()}`. `Feature2130RatchetWheel::{GetWheelMode(short*), SetWheelMode(short), Reset()}` and log `SetWheelMode(divert = %d)`.
- `IIFeature2121HiResWheel::Report::onWheelMovement(bool, unsigned, int, int)` is a stub in this binary that returns its first argument (Hopper, before shutdown). The real decode is in the producer path, not yet found.
- `onWheelMovement` body (Hopper pseudocode, read before shutdown) [V, partial]:
  - Logs the trace line above.
  - Checks a version-like field (`r24[0xe] < 3`) that gates one path.
  - If `period`/`deltaV` high bit is clear, it proceeds. It negates `deltaV`/`deltaH` when `(high_resolution|...)` is set. It then reads `_get_speed_cached()` and `_is_smooth_cached()` and calls a virtual sink at vtable+0x10 with `(smooth, speed, double, period, timestamp)`. The sink is the scroll engine's wheel handler [I].
  - When both deltas are zero it logs `onWheelMovement zero movement` and returns.
- `supports_high_resolution()` returns the constant 1 [V].
- `gestures::gestures::smooth_scrolling()` returns the byte at `this+0x8c` under a reader lock [V]. `set_smooth_scrolling(bool)` at 0x10166ee08 [V address, body not read].
- Settings persistence: `TouchpadGestures::SetSmoothScrollEnabled/GetSmoothScrollEnabled` [V]. `mouse.proto` `ScrollWheelSettings { double speed=1; WheelDirection dir=2; bool isSmooth=3; SmartShiftSettings smartshift=4; VirtualThumbwheel virtual_thumbwheel=7; }` [V].

### 3.2 Addresses (V)
- `devio_feature_2121_gesture::onWheelMovement(bool,uint,int,int)` = 0x10093036c (263 instructions).
- `devio_feature_2121_gesture::_set_parameters(bool,bool)` = 0x10092f91c.
- `devio_feature_2121_gesture::_set_mode(mode const&)` = 0x10092ede0.
- `devio_feature_2121_gesture::onSettingChange(...)` = 0x10093006c.
- `supports_high_resolution()` = 0x100930064.
- `devio_feature_2130::onWheelMovement(int,int)` = 0x100939740.
- `gestures::gestures::smooth_scrolling()` = 0x101673410.
- `gestures::gestures::set_smooth_scrolling(bool)` = 0x10166ee08.
- `devio_feature_smartshift::{_on_register, _set_settings, wheel_mode(bool), read_capabilities}` = 0x10098d948, 0x10098d12c, 0x10098de48, 0x10098c4b0.
- `devio_feature_scroll_wheel::{_on_register, _get_params, _set_params}` = 0x100984054, 0x1009849a4, 0x100984aac.

### 3.3 Wheel report to siminput (V, proto)
- `siminput.proto` `Input.MouseWheel`: `double delta_x=1; double delta_y=2; Input.WheelMoveMode mode=3; uint32 period_count=4; uint32 period_ms=5; double sensitivity=6;` plus nested `MacOsScrollWheelParameters { bool disable_acceleration=1; uint32 screen_dpi=2; double mac_min_scroll_speed=3; double mac_max_scroll_speed=4; }`. `enum WheelMoveMode { UNKNOWN_MODE=0; PER_PIXEL_MODE=1; PER_LINE_MODE=2; }`. `Input.RatchetSwitch { bool ratchet=1; }`. `Input.ScrollMultiplier { uint32 multiplier=1; }`.
- [resolved] `line_factor` is MouseWheel field 9 (section 11.4).
- Mapping (inferred [I]): `deltaV` from the 2121 report goes to `delta_y`, `deltaH` to `delta_x`. `period` goes to `period_count`. `period_ms` comes from the device report timing. `high_resolution` selects PER_PIXEL vs PER_LINE. `sensitivity` comes from speed.
- The conversion itself is in the sink, which was not read.

### 3.4 When the agent does NOT divert
- `diverted=0` in `_set_parameters` means the device sends native HID wheel reports. The OS scrolls natively. `_is_smooth_cached()` decides whether the agent's scroll engine also runs. [I]
- `supports_high_resolution()` is hard-coded 1, so the agent's wheel path always reports as high-res. Whether the device is set to high-res depends on `GetWheelCapability` (the `multiplier` field) [V strings].

### 3.5 Open items
- [resolved, round 2] Bytes sent by SetWheelMode and read by GetWheelMode/GetWheelCapability: section 11.1. Public numbering: fn 2 for `SetWheelMode`, fn 1 for `GetWheelMode`, fn 0 for `GetWheelCapability`, event 0 for the wheel report, event 1 for ratchet switch [P]. Bit positions for diverted (target), high_resolution, inverted, priority, rate, analytics [P: bit0 target, bit1 resolution, bit2 invert, bit3 ratchet?]. Confirm with the `SetWheelMode` disassembly (0x1003d2d38 and 0x1003d2dd0) and the `GetWheelMode` bit extraction at 0x1003d2a00.
- [partial] The sink is `this+0x2b8` (section 11.3). Its body and the `period_ms` computation are not in decomp/.

## 4. SmartShift (0x2110 / 0x2111)
- `Feature2110SmartShift::{GetCapabilities, GetRatchetControlMode, SetRatchetControlMode(uint, Byte, Byte, ...)}` and the same on 2111 with tunable torque [V]. `devio_feature_smartshift::{wheel_mode(bool), read_capabilities, _set_settings(SmartShiftSettings&)}` [V].
- Payload fields for SmartShift mode and threshold [P]: byte0 = mode (1 freespin / 2 ratchet), byte1 = auto-disengage threshold, byte2 = torque (2111). Not verified.

## 5. Ratchet and thumbwheel
- 0x2130 RatchetWheel: `GetWheelMode(short*)`, `SetWheelMode(short)`, `Reset()`. `Report::onWheelMovement` and `Report::onModeChanged` [V]. `getAnalysisData(posX, negX, posY, negY)` [V].
- 0x2150 Thumbwheel: `GetThumbwheelInfo(ushort*, ushort*, Direction*, bool*x3)`, `GetThumbwheelStatus(ReportingMode*, bool*x3)`, `SetThumbwheelReporting(ReportingMode, bool)` [V]. Log `feature_2150 internal_set_reporting (diverted = %s, inverted = %s)` [V].

## 6. Diverted controls (0x1B04, 0x6501, 0x4600)

### 6.1 REPROG_CONTROLS_V4 (0x1B04) [V names, P numbering]
- `GetCount`, `GetCtrlIdInfo(cid)` and the multi-output overload, `GetCtrlIdReporting(cid)`, `SetCtrlIdReporting(cid, Byte flags, remap, Byte flags2)` (+Async), `GetCapabilities`, `ResetAllCidReportSettings(Async)` [V].
- Logs: `feature_1b04 %s cid %d _divert raw xy: %s, raw wheel: %s`, `feature_1b04 %s cid %d _undivert` [V].
- `Feature1B04SpecialKeys::KeyReport::OnKeyDiverted` [V].
- Flags [P]: byte0 bits = temporary divert, persistent divert, raw XY, force raw XY; the second byte carries the raw wheel bit. Exact bit positions to confirm.
- `special_keys_divert_state` is stored in a settings file (`/devices/%s/special_keys_divert_state`). `SpecialKeysDivertState` and `DivertStateRequest` are in `devices.proto` [V].
- `DivertType` in `devices.proto` (`SpecialKeyUsage.DivertType`) [V].

### 6.2 Gestures (0x6501) and Crown (0x4600) [V names]
- `Feature6501Gestures::Divert(gesture_index, divert)`, `IsDiverted`, `DivertNow(cid, bool)`, `GestureReport::OnGestureDiverted`.
- Crown 0x4600: `feature_4600 %s ratchet mode is set to %d`, `reporting diverted is set to %d`, `_set_ratchet_mode`, `apply_ratchet_configuration`.

### 6.3 Button remapping
- `devices.proto` and the agent settings carry the mapping. Control IDs are CIDs from the REPROG table. The gesture button uses a CID from `defaults/defaults_control_osx.json` (for example "420fd454-..." and CIDs "424", "216", "217" appear in `defaultAssignment`). [V]

## 7. Virtual HID and event injection
- Imports present in the binary [V]: `_IOHIDUserDeviceCreateWithProperties` and `_IOHIDPostEvent` (undefined symbols in nm).
- Logi's own virtual device classes: `logi::devices::virtual_device::{virtual_device_interface, software_events::software_events_device_interface, radial_menu::radial_menu_device_interface, virtual_device_enumerator}`. `software_events_device_interface::{create, _register_endpoints, load_slots_metadata}`. `shared::software_events_virtual_device_id()/pid()` [V]. These carry software events (hotkeys, app events, macros) rather than mouse motion.
- [resolved] `IOHIDUserDeviceCreateWithProperties` is used for the virtual keyboard only (section 11.6).
- Scroll injection is not via IOHIDPostEvent in the code paths read so far. The scroll engine (`gesture_handler_2_finger_scroll_*`, `injector_InjectScrollX_Y_...`, `wheel_disturbance_filter_*` in `decomp/scroll/`) is the injector. It is ObjC and was already dumped. [V file list]

## 8. Device database

- `data/options_devices.json`: `{"devices":[...]}` with 13 records. Fields: `modelId` (string hex, e.g. "44054", "4077", "8c408"), `displayName`, `type` (`MOUSE` or `KEYBOARD`), `thumbnail` (`pipeline://logioptionsplus/thumbnails/...`), `winSupport`, `macSupport`. Model IDs appear both as full and short forms (e.g. "8c408" and "c408"), which probably maps the 16-bit PID and the Bluetooth product ID. [V structure, I for the mapping]
- `data/guru_devices.json`: `{"devices":[...]}` with 6 records. Fields: `modelId`, `displayName`, `type` (e.g. `PRESENTER`), `thumbnail`. Spotlight is `6b503`. [V]
- `data/DeviceCompatibility.json`: `{"v1":{"version":"1","map":{"bb00":"bbxx","b031":...},"bbxx":["info","pairing","dfu"],"b031":["info","pairing","dfu"]}}`. The map groups PIDs into compatibility families, each with the supported operations. [V]
- `data/defaults/defaults_control_{osx,win}.json` and `defaults_slot_{osx,win}.json`: `{"defaults":{<key>:{"defaultAssignment":[{"id":"424","cardInfo":"card_global_presets_gesture_button_highlights","tags":["UI_PAGE_BUTTONS"]}, ...]}}}`. Keys are either assignment UUIDs or `application_id_*`. [V]
- Other data used by a reimplementation: `applications.json`, `device_analytics_config.json`, `data/rap/*` (card tags and recommendations), `data/overlay/icons`, and `data/strings/*.yaml` (19 locales). [V existence]
- The `.pem` keys (`firmware.pem`, `logitech-lap-public.pem`) are noted, not used.

## 9. Open questions (after round 2)
1. 0x2121 event (wheel report) byte decode: the Report decoder that produces `onWheelMovement(bool, uint, int, int)` is not in decomp/ (no `IIFeature2121HiResWheel::Report` body). Only the consumer is verified (section 11.3).
2. HID++ report IDs (0x10/0x11/0x12) and the per-interface size map. `Device::feature_payload_per_packet` is a runtime tree lookup at `this+0x7e0`; its population code is not dumped.
3. 1B04 SetCtrlIdReporting flag bit meanings: the observed constants are 0x03, 0x0c, 0x23, 0x33 (section 11.5). Exact names still to confirm.
4. Which devio classes are behind the `IIFeature2121HiResWheel::Report` producer and the 0x2130 `Report::onWheelMovement` decoder.
5. Whether 0x0100-0x0103 are standard or Centurion-only feature IDs (still unresolved).
6. BLE service role: 0x0001-series vs 0x0005-series UUIDs (section 11.2) are mapped by address only; roles are inferred.
7. DriverKit "maskable HID" dext (section 11.4): how it interacts with diversion for mice is open. Not traced.

## 10. Method notes
- Round 2: `decomp/` and `otool` (shared `all.s` in scratchpad) were used. Scripts `near.py` (address-to-symbol search) and `fnasm.py` (function disassembly with filter) are in the scratchpad.
- Symbols: `grep -E 'devio::...' bin/symbols.txt` (nm -C output).
- Disassembly: `otool -tV bin/logioptionsplus_agent.arm64 > <scratch>/text.s`. A helper `fn.py` lists `bl` callees by address. Callees through `__stubs` are not resolved to names; that needs the stub-to-import map.
- Pseudocode for `onWheelMovement` and `smooth_scrolling` came from REA/Hopper before the coordinator shut it down. Other functions were not decompiled.

## 11. Round 2 resolutions (decomp/devices, decomp/glue, decomp/scroll, otool, protos)

Sources: `decomp/devices/*.m`, `decomp/glue/*.m`, `decomp/scroll/*.m` (Hopper pseudocode, read-only), `otool -tV` text in the scratchpad (`all.s`), `protos/logi/protocol/siminput.proto`. Addresses are the Hopper/otool entry points.

### 11.1 HiRes wheel (0x2121) request layouts [V]
Generic send/receive is vtable slot `+0x18` with `(function_index, payload_in, out_begin, out_end, ...)`. Function indices: 0 = GetWheelCapability, 1 = GetWheelMode, 2 = SetWheelMode. These match public HID++ 2.0 [P]. The response payload is copied into a buffer zero-padded to 16 bytes (`0x10 - size`), which matches the HID++ long report parameter length (16) [V for padding, P for the report ID].

- SetWheelMode request, 3 bytes (`Feature2121HiResWheel::SetWheelMode(bool diverted, bool high_res, bool inverted, uint priority, uint rate, bool analytics, ...)`, 0x1003d2dd0). The code builds `new byte[3]`:
  - byte0 = `diverted | (high_res ? 0x02 : 0) | (inverted ? 0x04 : 0) | (analytics ? 0x08 : 0)`
  - byte1 = priority (uint8 from arg4)
  - byte2 = rate (uint8 from arg5)
  - Gated by `devio::Feature::set_configured()`. Calls vtable `+0x18` with fn 2.
- GetWheelMode response (`0x1003d2a38`, 6 outputs): byte0 bit0 = diverted, bit1 = high_res, bit2 = inverted, bit3 = analytics; byte1 = priority; byte2 = rate. Requires payload size > 2 (else errcode 2).
- GetWheelCapability response (`0x1003d26d4`, 8 outputs): byte0 = multiplier. byte1 bit0..bit4 = the five bool capabilities, in the parameter order arg2..arg6. The logs suggest bit0 = has_priority, bit1 = has_rate, bit2 = has_ratchet_switch, bit3 = has_inversion, bit4 = has_analytics_data [I, from log order]. byte2 = ratchets_per_rotation. byte3 = wheel_diameter. Requires payload size > 1.
- Mode struct used by the agent (`devio_feature_2121_gesture::_set_mode`, 0x10092ede0): `[0]=diverted, [1]=high_resolution, [2]=inverted`, then priority/rate/analytics at later offsets (not fully decoded).

### 11.2 BLE UUIDs (binary strings, by address) [V addresses; roles I]
- `00010000-0000-1000-8000-011F2000046D` at 0x2e13c32 (service)
- `00010001-0000-1000-8000-011F2000046D` at 0x2e14092 (characteristic)
- `00050000-0000-1000-8000-011F2000046D` at 0x2e13c57 (service)
- `00050001-0000-1000-8000-011F2000046D` at 0x2e140b7 (characteristic)
- The Logitech base UUID suffix is `-011F2000046D`. The 0x0001 pair is most likely the HID++ channel used by `BleppBus` (`on_device_blepp`, `on_report`, `ble_monitor_report`). The 0x0005 pair is likely a second channel (pairing or DFU) [I]. Confirm the write/notify direction from `BleppBus::on_device_did_write` / `on_device_blepp` disassembly.

### 11.3 Smooth scrolling: diversion decision logic and the wheel path [V]
- `devio_feature_2121_gesture::_set_parameters(bool diverted, bool inverted)` (0x10092f91c). Log: `_set_parameters(diverted=%d, inverted=%d, _is_smooth_cached()=%d)`. The decision is:
  - `smooth = gesture_handler::_is_smooth_cached()`
  - `mode.diverted = diverted || smooth`
  - `mode.high_resolution = smooth`
  - `mode.inverted = inverted`
  - then `_set_mode(mode)`, which sends SetWheelMode (11.1) only when the mode actually changes.
  - **So: smooth scrolling on means the wheel is diverted to HID++ with high-resolution reporting. Smooth off and no explicit divert request means native HID scrolling (diverted=0, high_res=0).** The `supports_high_resolution()` method returns 1 (0x100930064).
- `gestures::gestures::set_smooth_scrolling(bool)` (0x10166ee08) stores the flag in the gestures object at `+0x8c` under a writer lock, then calls `set_wheel_multiplier`. `smooth_scrolling()` reads the same byte [V].
- `IIFeature2121HiResWheel::Report::onWheelMovement` in the binary is a stub that returns its first argument (0x100930e6c). The real decoder is not in decomp/ (open item 1).
- `devio_feature_2121_gesture::onWheelMovement(bool high_res, uint period, int deltaV, int deltaH)` (0x10093036c):
  - Logs `feature_2121 %s onWheelMovement(high_resolution=%d, period=%d, deltaV=%d, deltaH=%d)`.
  - If both deltas are zero it logs `zero movement` and returns.
  - Otherwise it negates `deltaV` and `deltaH` (`cneg`) when the inverted condition holds, then calls the sink through vtable `+0x10` as `sink->(smooth_cached, speed_cached (double), period, timestamp)`. The sink is a member at `this+0x2b8` [I: the scroll engine adapter].
- Scroll engine entry: `gestures::gestures::scroll(int dx, int dy, int period, uint64 timestamp, double yFixedLineFactor)` (0x101670570). Log `gestures::scroll (dx = %d, dy = %d)`. It calls `[wheel_mouse_handler setYFixedLineFactor:]` then `[wheel_mouse_handler onMouseWheelWithPeriod:period deltaV:dy deltaH:dx timestamp:ts]` [V].
- `wheel_mouse_handler onMouseWheelWithPeriod:deltaV:deltaH:timestamp:` (0x101686a28) [V]:
  - If `deltaV == 0 && deltaH != 0`, sets horizontal-only and uses deltaH as the value.
  - Multiplies the value by a sign (`cneg`) and by a scale.
  - Loops `period` times: `postMouseWheel:(value*scale) horizontal:h accelerate:[self accelerate] scrollphase:0 pcount:period pnum:i timestamp:ts`. So one device wheel report becomes `period` sub-events, with `pcount=period` and `pnum=i`.
- `wheel_mouse_handler postMouseWheel:horizontal:accelerate:scrollphase:pcount:pnum:timestamp:` (0x101686d40) [V]:
  - Time since last report: `d8 = (timestamp - last_ts) / 1e9` (1e9 constant `0x41cdcd6500000000`).
  - Per-sub-event period: `d11 = d8 / pcount`.
  - Threshold: 0.008 s (0x3f80624dd2f1a9fc). If `d11 >= 0.008`, `d14 = d11`. Otherwise the ratchet/wheel detector state is reset and `d14` stays at 0.008. The `-0.1` (0xbfb999999999999b) branch sits inside the `>= 0.008` case, so it is unreachable as written.
  - `d14` is passed to the wheel detector as `timeSinceLastReport:`.
- `ScrollingGestureState::OnInput` and `feature_1b04_special_keys::onRawWheel` / `_create_send_input_scrollwheel` exist in decomp/ (glue/devices), but their protobuf field writes are not named in the dump. The MouseWheel field numbers are in the proto (below).

### 11.4 siminput Input.MouseWheel (proto, complete) [V]
From `protos/logi/protocol/siminput.proto` (lines ~86-100):
- 1 `delta_x` (double), 2 `delta_y` (double), 3 `mode` (WheelMoveMode: UNKNOWN_MODE=0, PER_PIXEL_MODE=1, PER_LINE_MODE=2), 4 `period_count` (uint32), 5 `period_ms` (uint32), 6 `sensitivity` (double), 7 `smooth_scrolling` (bool), 8 `timestamp` (uint64), 9 `line_factor` (double), 10 `macos_scroll_wheel_parameters` (MacOsScrollWheelParameters: disable_acceleration, screen_dpi, mac_min_scroll_speed, mac_max_scroll_speed).
- `line_factor` is field 9. The earlier "not in proto" note was wrong (my first read was truncated).
- Consumer: `logi::siminput::virtual_input_osx::simulate_mouse_input` (0x1011fe27c). For `Input.mouse` wheel it calls `logi::scrolling::get_scroll_manager()` and then its vtable `+0x10` with the MouseWheel message and the ScrollMultiplier (Input field 9). Mouse move and button cases use `CGEventCreateMouseEvent` + `CGEventPost` [V].
- The mapping from the 2121 report to these fields (period_ms, sensitivity) is inferred [I] from the period math in 11.3.

### 11.5 1B04 SetCtrlIdReporting flags [partial V]
- `Feature1B04SpecialKeys::SetCtrlIdReporting(cid, flags, remap, flags2)` forwards to vtable `+0xc8` with the arguments `(cid, flags & 0xff, remap, flags2 & 0xff)` (`Feature1B04SpecialKeys::SetCtrlIdReporting`, 6-line body).
- `feature_1b04_special_keys::_divert(cid, bool, bool)` uses flag bytes `0x03`, `0x0c`, `0x23`, `0x33`, and `0x08`/`0xc` depending on device type (`_is_mouse`, `_is_presenter`). The `ctrlid_flags_manager::get_by_ctrlid` lookup supplies a per-CID flag. These match the REPROG v4 pattern where the low nibble is the value and the high nibble is the "change" mask [P]. Exact bit names are still to confirm.

### 11.6 Virtual HID and event injection [V]
- `IOHIDUserDeviceCreateWithProperties` is called only in `logi::gestures::gestures::create_virtual_hid_keyboard()` (0x101672944). It uses a 65-byte keyboard report descriptor (`kbHidDescriptor`, `length:0x41`) and sleeps 10 ms (`usleep(0x2710)`). It is a virtual HID keyboard for key and aux-key injection (`IOHIDPostHIDKey`, `IOHIDSystemUtils_postAuxKey`, `virtual_input_osx::send_aux_code`).
- Mouse motion and scroll are not injected through IOHIDUserDevice. They go through CGEvent (`CGEventPost`) and the scroll manager (11.3, 11.4).
- `IOHIDPostEvent` is an import. Its call sites were not separately identified. It is likely the system-event path inside `IOHIDSystemUtils` [I].
- A separate DriverKit system extension exists: `logi::dext_manager` (`activate_dext`, `initialize_hid_mgr`, `deviceMatchingCallback`, `is_dext_device`) and `logi::hidio::maskable_hid_dext_device_impl_osx` (`create_controls`, `get_feature`, ...). The dext matches VendorID 0x046D through `initialize_hid_mgr` (0x10001006c). Its role in diversion is not traced [open item 7].

### 11.7 IOHID matching constants [V]
- `devio::MacOSBus::createMatchingDict(unsigned vid)` (0x10025a404): when `vid == 0x046D` it builds two matching dictionaries:
  - `{DeviceUsagePage: 0xFF00, DeviceUsage: 2}` (stp w8=2, w9=0xff00)
  - `{DeviceUsagePage: 0xFF43, DeviceUsage: 0}` (stp wzr, w8=0xff43)
- `devio::MacOSDevice::getHidProperties()` (0x1002639c0) also checks usage pages 0xFF00 and 0xFF43 [V].
- The HID++ collection is usage page 0xFF00 (usage 1 or 2) on short/long reports [P]. 0xFF43 is a second Logitech vendor page (probably a secondary or lighting channel) [I].

### 11.8 Device payload size and runtime tables [V]
- `devio::Device::feature_payload_per_packet(DeviceInterface)` (0x1000d2e3c) is a lookup in a `std::map` rooted at `this+0x7e0` (DeviceInterface key). It returns the mapped value or 0. The population code is not in decomp/. So the size map is data-driven at runtime; the exact sizes are unresolved (open item 2).

## 12. Corrections to earlier sections
- "line_factor not in siminput" is wrong. It is field 9 (section 11.4).
- "IOHIDUserDevice used for input injection" is wrong. It is a keyboard virtual device (section 11.6).
- Section 3.4's "diverted=0 means native" is now confirmed by `_set_parameters` (section 11.3).

## 13. 0x2121 notification decoder (resolved, [ASM] `devio::Feature2121HiResWheel::onFeatureReport` @0x1003d4cf8)

`onFeatureReport(int eventIndex, const vector<Byte>& params)`; params are the HID++ payload after the 4-byte header
(report id, device index, feature index, function/event<<4 | swid).

| event | min len | decode | produced as |
|---|---|---|---|
| 0 (wheelMovement) | 5 | `hiRes = (b0 >> 4) & 1`; `periods = b0 & 0x0F`; `deltaV = Int16(b1<<8 \| b2)`; `deltaH = Int16(b3<<8 \| b4)` | `IIFeature2121HiResWheel::Report::onWheelMovement(hiRes, periods, deltaV, deltaH)` |
| 1 (ratchetSwitch) | 1 | `ratchet = b0 & 1` | `RatchetSwitch::onRatchetSwitch(ratchet)` |
| other | – | ignored | – |

The sign extension is `sxth` on the high byte shifted left by 8, ORed with the low byte, so it's big-endian signed 16-bit. This matches public HID++ 2.0 docs and Solaar.
