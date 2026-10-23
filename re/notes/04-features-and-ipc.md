# 04 - Features, IPC and persistence (Logi Options+ macOS 2.6.944893)

Scope: Electron UI <-> `logioptionsplus_agent` transport, route catalog, feature inventory, per-app profiles, settings storage, launch/permissions.
Method: static analysis of `asar/deob` (webcrack output), `asar/extracted`, `protos/`, `data/`, `bin/logioptionsplus_agent.arm64` strings, bundle plists. No runtime capture. No Hopper/`mcp__rea__*` Hopper tools used. No `.env`, key, cookie, blob_storage or account data read. Settings DB inspected for schema/key shape only.

Labels: **V** = verified in the code or data read directly. **I** = inferred from naming or partial evidence. **?** = open.

File paths below are relative to `/Users/nkl/dev/personal/logi/re/` unless absolute.

---

## 1. IPC transport

### 1.1 Layers

| Hop | Mechanism | Evidence | Label |
|---|---|---|---|
| Renderer (app.min / cc.min) -> Electron main | `ipcRenderer.send/invoke` on channel names in `SocketEvent` (`CREATE_CONNECTION`, `CONNECT_AGENT`, `SOCKET_SEND`, `SOCKET_ON_MESSAGE`, `SOCKET_GET_STATE`, ...) | `asar/deob/preload.bundle/deobfuscated.js:380-393` (preload wrappers), `asar/deob/main/deobfuscated.js:768-775` (channel names) | V |
| Electron main -> agent | Node `net.createConnection(connectionPath)` (Unix domain socket on macOS). Auto-reconnect, `reconnectInterval: 100` for the main agent connection | `asar/deob/main/deobfuscated.js:3668-3684` (config), `:4824-4860` (`netSocket`, `net.createConnection` at `:4840`), `:71534` (`require("net")`) | V |
| Socket path (main agent) | `N("logitech_kiros_agent")`. Helper `N` builds `/tmp/<name>-<md5(username)>` on macOS, `\\.\pipe\<name>-<md5>` on Windows. The helper shown at `:3157-3166` is in the plugin-service module, so it is the same function only if the module scope is shared (I). Hash input is the OS username; do not print it | `asar/deob/main/deobfuscated.js:3157-3166`, `:3671` | V (macOS form), I (same N in the agent-connection module) |
| Plugin-service socket | `/tmp/LogiPluginService-<md5>` (Windows: named pipe) | `asar/deob/main/deobfuscated.js:3156-3161` | V |
| Voice socket | `logitech_kiros_logivoice` (reconnect 2000 ms, max 10000) | `asar/deob/main/deobfuscated.js:3706-3711` | V |
| CC (control center) socket | `/tmp/${C}` or `\\.\pipe\${C}` (`C` not resolved here) | `asar/deob/main/deobfuscated.js:3742-3743` | V (shape) |
| Agent server side | C++ `logi::api::named_pipes::Server` / `ServerEndpoint` / `Subscriptions`; also `logi::api::websocket::Server` with `open_websockets_port_if_needed` and `wss://` string | `bin/symbols.txt:85880-85901`, `:82704`, `:83187-83188` (`backend_first/last_websocket_server_port`), `strings bin/logioptionsplus_agent.arm64` | V (symbols); I (the Electron socket is served by `named_pipes::Server`) |

### 1.2 Framing (Electron main <-> agent)

Implemented in `network` (`asar/deob/main/deobfuscated.js:8019-8210`, reader state machine `:8080-8130`, writer `send` `:8166-8172`).

Writer, per message:

```
u32LE  bodyLen = payloadLen + 12  (code: len("json") + payloadLen + 8)
u32BE  4                     (length of protocol tag)
ASCII  "json"                (protocol tag)
u32BE  payloadLen
bytes  payload               (UTF-8 JSON)
```

Reader state machine: `START` (skip 4 bytes) -> `PROTO_HEADER` (u32BE tag length) -> `PROTO_PAYLOAD` (tag) -> `MESSAGE_HEADER` (u32BE payload length) -> `PAYLOAD`. Only tag `json` is accepted; anything else logs "Unsupported Protocol" (`:8052-8064`).

Payload is `JSON.parse`d and forwarded to the renderer on `SOCKET_ON_MESSAGE` (`asar/deob/main/deobfuscated.js:4905-4935`, `C()` function). Messages are JSON, so the agent-side JSON <-> protobuf translation has to exist somewhere (I, not located).

Verified outbound envelope (renderer builds it, main forwards it):

```json
{ "msg_id": "<incrementing string>", "verb": "GET|SET|SUBSCRIBE|UNSUBSCRIBE|REMOVE|BROADCAST|...", "path": "/route/like/this", "payload": { ... } }
```

- Built in `asar/deob/app.min/40109.js:750-765` (`msg_id`, `verb`, `path`, optional `payload`). The same shape is built in main for analytics (`asar/deob/main/deobfuscated.js:9454-9465`, `verb: "SET", path: "/scarif/event"`).
- Callbacks are stored by `msg_id` and resolved on reply (`asar/deob/app.min/deobfuscated.js:6915-6929`, map `_0x322b9d[id] = callback`).

Verb enum, verified in two places: `asar/deob/app.min/92927.js:15-16` (`GET, SET, REMOVE, SUBSCRIBE, UNSUBSCRIBE, BROADCAST`; statuses `SUCCESS`, `FAULTED`) and `protos/logi/common_protocol/message.proto` (`Message.Verb`: INVALID, GET, SET, BROADCAST, REMOVE, SUBSCRIBE, UNSUBSCRIBE, OPTIONS).

### 1.3 Protobuf envelope (agent side)

`protos/logi/common_protocol/message.proto`:
- `Message { string msg_id=1; Verb verb=2; string path=3; string origin=4; Result result=5; google.protobuf.Any payload=6; }`
- `Result { Code code=1; string what=2; }`, codes SUCCESS=1 and negatives: INVALID_ARG, INVALID_DEVICE, NO_SUCH_PATH, CANCELLED, NOT_IMPLEMENTED, INVALID_VERB, NOT_READY, FAULTED, UNREACHABLE, UNAUTHORIZED, DUPLICATE_NAME, NOT_FOUND, EXCEPTION, CONFLICT, LUS_ERROR.
- `Routes { Route { verb, path, payload, example_json, endpoint } }` is an agent-side route-introspection message. Its existence suggests the agent can dump its own route table. Not verified at runtime.

Route strings in the agent also appear as `/routes` in `strings` (I: this is the introspection endpoint).

### 1.4 Route naming scheme

Paths are slash-separated, lowercase snake_case, grouped by feature. Examples:
- Per-device: `/devices/<id>/...`, `/backlight/%s/backlight_level`, `/battery/%s/state`, `/flow/%s/config`, `/haptics/%s/play_waveform`, `/coupled_easy_switch/%s/...` (`strings bin/logioptionsplus_agent.arm64`, format strings).
- Settings configure: `/<feature>_settings/configure` and `/<feature>/configure`. Verified literal list in agent strings: `/mouse_settings/configure`, `/mouse_scroll_wheel_settings/configure`, `/mouse_thumb_wheel_settings/configure`, `/mouse_precision_mode/configure`, `/touchpad_settings/configure`, `/touchpad_gesture/configure`, `/keyboard_settings/configure`, `/backlight_settings/configure`, `/illumination_light_settings/configure`, `/haptic_settings/configure`, `/fn_inversion_settings/configure`, `/force_sensing_settings/configure`, `/disable_keys_settings/configure`, `/disable_keys_capabilities/configure`, `/layer_config_settings/configure`, `/craft_crown_settings/configure`, `/presenter_settings/configure`, `/presentation_timers/configure`, `/brightness_settings/configure`, `/webcam_*_settings/configure`, `/gesture/configure`.
- The renderer decides the configure route from the card key. `asar/deob/app.min/deobfuscated.js:164585-164600` defines `mouse_settings`, `mouse_scroll_wheel_settings`, `mouse_thumb_wheel_settings`, `force_sensing_settings`, `horizontal_scroll` (remapped for some devices), and `smart_zoom_configuration`. (I: the final path is `/<key>/configure`; the string concatenation was not traced to the send call.)
- Inventory of ~430 distinct paths: `strings bin/logioptionsplus_agent.arm64` (grep `^/`) and renderer literals (`rg '"/[a-z]'` over `app.min`, `cc.min`).

### 1.5 Mouse and device route table (for the reimplementation)

Setting ids and the card JSON they map to are verified in `asar/deob/app.min/deobfuscated.js:124007-124014` (ids) and `:124860-124960` (mapping). Proto types are in `protos/logi/protocol/mouse.proto`.

| UI setting id | Feature enum (HID++) | Route (configure) | Card JSON fields (renderer read) | Proto (mouse.proto) | Label |
|---|---|---|---|---|---|
| `scroll_wheel_speed` | HIGH_RESOLUTION_SCROLLING_2121 | `/mouse_scroll_wheel_settings/configure` | `mouseScrollWheelSettings.speed` (UI `spd = round((speed+1)*50)`, default 50) | `ScrollWheelSettings.speed` (double) | V |
| `scroll_wheel_direction` | same | same | `mouseScrollWheelSettings.dir` (lowercased on Mac; default `_0x2f8560` on Mac) | `WheelDirection dir` | V |
| `scroll_wheel_smooth` (Smooth scrolling) | same | same | `mouseScrollWheelSettings.isSmooth` (0/1) | `ScrollWheelSettings.isSmooth` | V |
| `smart_shift_status` (SmartShift on/off) | SMARTSHIFT | same | `mouseScrollWheelSettings.smartshift.isEnabled` | `SmartShiftSettings.is_enabled` | V |
| `smart_shift_fixed_mode` (ratchet/free) | SMARTSHIFT | same | `smartshift.mode` (lowercased) | `SmartShiftSettings.mode` (`ScrollMode`) | V |
| `smart_shift_sensitivity` | SMARTSHIFT | same | `smartshift.sensitivity` (default 50) | `SmartShiftSettings.sensitivity` (uint32) | V |
| `scroll_force` | SMARTSHIFT | same | `smartshift.scrollForce` (default 50) | `SmartShiftSettings.scroll_force` | V |
| `thumb_wheel_direction` | THUMB_WHEEL_2150_SETTINGS | `/mouse_thumb_wheel_settings/configure` | `mouseThumbWheelSettings.dir` | `ThumbWheelSettings.dir` | V |
| `thumb_wheel_sensitivity` | THUMB_WHEEL_2150_SETTINGS | same | `mouseThumbWheelSettings.speed` (UI `floor((1+speed)*50)`) | `ThumbWheelSettings.speed` | V |
| `pointer_speed` (+ `extdpi` = highResolutionSensorActive) | POINTER_SPEED | `/mouse_settings/configure` | `mouseSettings.pointerSpeed.active.value` (UI `round((v+1)*50)`), `defaultTrackingSpeed` | `PointerSpeed.PointerSpeedValue {value, high_resolution_sensor_active, dpi_level}`; `Settings.default_tracking_speed` | V |
| Precision mode | (PrecisionMode) | `/mouse_precision_mode/configure` | (not traced) | `PrecisionMode.active` | V (proto), I (UI) |
| Report rate / DPI table | (Dpi) | (under `/mouse_settings`) | | `Settings.report_rate`, `Settings.dpi_table`, `Dpi.Info` | V (proto) |
| Button remap (`button_map`) | (special keys/CID) | `/input/button_map`, `/keyboard...` (not traced fully) | | `CidsWithoutOOBActions`, `Assignment` in `profiles_v2.proto` | I |
| Left/right swap | | `/mouse/global/swap`, `/mouse/swap` | | `MouseButtonSwap` | V (route), V (proto) |
| Virtual thumbwheel | | (scroll wheel) | `virtual_thumbwheel` | `VirtualThumbwheel` | V (proto) |

Important caveat for the port: the UI converts agent values in the range -1..1 to 0..100 with `(x+1)*50`. Keep those conversions when porting.

### 1.6 Keyboard, Easy-Switch, Flow, battery, haptics, backlight (route level)

From `strings bin/logioptionsplus_agent.arm64` (V = literal in agent; proto files listed for types):

| Area | Routes | Proto |
|---|---|---|
| Devices | `/devices/list`, `/devices/state/changed`, `/devices/state/activated`, `/devices/state/deactivated`, `/devices/model/info`, `/devices/support/info`, `/devices/resources` (+`/default_gestures`, `/default_slots`, `/dynamic_slots`, `/rac_slots`), `/devices/map`, `/devices/driver_info`, `/devices/host_changed`, `/devices/preferences/changed`, `/devices/change_owner`, `/devices/bt_report`, `/devices/quarantine_notification`, `/devices/unknown/connected`, `/devices/wheel_mode_shift`, `/devices/special_keys_divert_state/configure`, `/options/devices/list` | `devices.proto`, `devices_support.proto` | V |
| Easy-Switch | `/devices/easy_switch`, `/devices/%s/easy_switch`, `/devices/%s/easy_switch/change`, `/devices/state/easy_switch_cache_updated`, `/devices/ever_connected/list`, `/devices/ever_connected/clear`, `/coupled_easy_switch/%s/{compatible_devices,coupled_switch_link_device,follow_change_host,follow_cookies}`, `/coupled_easy_switch/add_pending_device` | `wireless.proto`, `coupled_easy_switch_assist.proto` | V |
| Flow | `/flow/%s/{config,config_changed,device_location,device_peer_status,discover,discover_progress,reset}`, `/devices/fn_inversion/notify` (Flow-related keyboard link is in `FLOW_*` strings) | `flow.proto` | V |
| Battery | `/battery/state/changed`, `/battery/warning`, `/battery/%s/{state,warning,lighting,sleep_timer,power_consumption/changed,state_override}`, `/low_battery/notify`, `/low_battery/rule`, `/charge_pad/...` | `devices.proto` (types I) | V |
| Backlight | `/backlight/%s/{backlight_level,backlight_duration,backlight_effect,power_save,state}`, `/backlight_settings/configure`, `/illumination_light_settings/configure`, `/illumination_light/light_settings_changed` | `backlight.proto`, `illumination_light.proto` | V |
| Haptics (mouse) | `/haptics/%s/{config,play_waveform,stop_waveform,status,start_breathing_exercise}`, `/haptic_settings/configure`, `/haptics/waveform/event` | `haptics.proto` | V |
| Fn lock / keys | `/keyboard/lock_key_pressed`, `/input_tracker/{caps_lock_pressed,fn_lock_pressed,num_lock_pressed,scroll_lock_pressed,start,stop,events}`, `/notifications/{fn_lock,fn_inversion,caps_lock,num_lock,scroll_lock}`, `/keyboard_settings/configure`, `/disable_keys_settings/configure` | `keyboard.proto`, `input_tracker`, `disable_keys.proto` | V |
| Force sensing / Crown / presenter | `/force_sensing_settings/configure`, `/craft_crown_settings/configure`, `/presenter/presenter_settings_changed`, `/presenter/vibrate`, `/presentation_timers/*`, `/logipresentation/*`, `/logihighlights/*` | `force_sensing.proto`, `crown.proto`, `presenter.proto`, `highlights.proto` | V |

### 1.7 Per-application profiles (routes)

| Area | Routes | Proto |
|---|---|---|
| App list | `/applications`, `/applications/all`, `/applications/installed`, `/applications/predefined`, `/applications/predefined/installed`, `/applications/scan`, `/applications/scan/installed`, `/applications/running`, `/applications/logi/installed`, `/application/installed`, `/application/additional_data`, `/application/command/colors`, `/application/require/restart/paths`, `/application/disable`, `/application/focus` | `applications.proto`, `application.proto` | V |
| Foreground focus | `/applications/focus/last`, `/application/focus`, `/plugin_foreground_notifier/notify/activate` | `application.proto` | V |
| Event triggers | `/applications/event/{register,unregister,raw,triggered,registered,unregistered}` | `system_events.proto` | V |
| Profiles | `/profile`, `/profile/landing`, `/profile/applicationList`, `/v2/profile`, `/v2/profiles`, `/v2/profiles/{update,slice,slice/preview,copy_settings,device/assignment_sync,device/assignment_sync_complete,integrations_restored}`, `/v2/profile/reset`, `/v2/assignment`, `/unified_profiles`, `/unified_profiles/{assignments,assignment/default,activities,activity,activity/{added,updated,removed}}`, `/card_by_app`, `/available_app` | `profiles_v2.proto`, `unified_profiles.proto` | V |
| Assignments and cards | `/assignment`, `/assignments`, `/add_cards`, `/rename_cards`, `/rac/supported_cards`, `/rap_v2/{presets,preset,available_app,card_by_app,app_id_name_map,supported_cards,rac_*}` | `rap_v2.proto`, `card_register.proto` | V |
| Macros | `/macros/{presets,predefined,device/predefined_ids,import,export,sequence/status,custom_categories/storage,ai_prompt_builder/enabled,ai_onboarding/completed,onboarding/ready}`, `/macro_assignment(s)/{create,update,remove,all,active,predefined,custom_categories}`, `/macro_infos/update`, `/software_events/try_macro`, `/software_events/slots/metadata` | `macros.proto`, `macros_categories.proto`, `software_events.proto` | V |
| Action invoke | `/action/invoke`, `/api/v1/actions/{invoke,register}`, `/system/hotkey/{register,unregister,triggered,pause,resume}`, `/software_events/shortcut/register/allowed` | `software_events.proto`, `integrations.proto` | V |

Per-app matching: `applications.json` (see section 3). Foreground app comes from the agent (`/applications/focus/last`). The agent-side focus tracker is not traced in code. Mark that as open (?). The "Secure input" route (`/get_secure_input_app_name`) and `/macos_security/input_monitoring` relate to macOS restrictions.

### 1.8 Other routes (for the feature inventory)

| Area | Routes (V) |
|---|---|
| Updates | `/updates/{status,info,next/info,check_now,periodic_check,download,install,restart_now,reset,channel,depot/info}`, `/firmwareupdate/launch/frontend`, `/dfu/update/available`, `/dfu/config/update`, `/installer/{install_depot_extension,uninstall_depot_extension,extension_state}` |
| Notifications / OSD | `/notifications/{post,toast/event,battery_status,backlight_changed,show_mode}`, `/notifications_settings`, `/uvc/showmode/notification`, `/radial_menu/*` (Actions Ring), `/low_light/notify` |
| Backups | `/backups/device/{list,start_backup,start_backup_all,start_restore,status_backup,status_restore,force_autobackup,wait_running_autobackups}`, `/backups/macros/{status_restore,clean_all}`, `/device/*_settings_restore` |
| Account (cloud) | `/accounts/{user_info,user_info_edit,login_websso,logout_session,register_email,register_email_status,email_subscription,config,cn_idaas_status}`, `/identity/oauth2/{token,revoke}`, `/identity/userinfo` |
| Offers / marketing | `/offer/{retrieve,redeem,revoke,update_status,promotion/request}`, `/api/offer/{available,claimed,redeem}`, `/star_rating/{trigger,modal_popup,submit,timer,notification_*}`, `/survey*` (survey.proto), `/device_recommendation_enabled`, `/pipl/status` |
| Analytics / telemetry | `/analytics/{send_event,data,status,collect_host_info}`, `/scarif/{event,info,status}`, `/crash_reporting/{crash,deadlock,status,manual_event,...}`, `/event_tracing/*`, `/logging/*` |
| Diagnostics | `/logioptions/info`, `/system/info`, `/permissions`, `/macos_security/{accessibility,input_monitoring,screen_recording,bluetooth}` (+ `/event`), `/bluetooth/open/settings`, `/system/open_settings`, `/device_restarter/restart_device`, `/rightsight/*` |
| Voice (LogiVoice) | `/logivoice/onboarding/*`, `/logivoice/{start,stop}_onboarding_mic_test`, `/microphone/{mode,polar_pattern}/changed` |
| Webcam (RightSight) | `/webcam_*_settings/configure`, `/webcam_in_use`, `/webcams/in_configuration_devices*`, `/device/camera_settings_restore`, `/device/crop_settings_restore`, `/device/focus_settings_restore` |
| Touchpad / test | `/touchpad_gesture/configure`, `/touchpad/gesture_reporting`, `/api/test_gestures*` |
| Lifecycle | `/lifecycle/backend_started`, `/lifecycle/backend_shutdown`, `/lifecycle/logivoice_shutdown`, `/launcher/{run,status}`, `/logioptions/launch/frontend` |

---

## 2. Feature inventory

Strings from `data/strings/en-US.yaml` (V). Core = needed for a mouse/keyboard replacement. Cloud/marketing = account, offers, telemetry, promos, or features outside the core scope.

### 2.1 Point & Scroll (mouse)

| Control | String key(s) | Setting id | Core? |
|---|---|---|---|
| Pointer speed (+ high-res sensor state) | `CONFIGURATION_TITLE_POINTER_SPEED` | `pointer_speed` | Core |
| DPI levels / report rate | (Dpi, Settings protos) | route `/mouse_settings` | Core |
| Acceleration / precision mode | `/mouse_precision_mode/configure`, `PrecisionMode` | `toggle_precision_mode` card (`card_global_presets_toggle_precision_mode`, task 196) | Core |
| Scroll speed | `CONFIGURATION_TITLE_SCROLLING_SPEED` | `scroll_wheel_speed` | Core |
| Scroll direction (natural) | `CONFIGURATION_TITLE_SCROLL_DIRECTION` | `scroll_wheel_direction` | Core |
| Smooth scrolling | `CONFIGURATION_TITLE_SMOOTH_SCROLLING` | `scroll_wheel_smooth` | Core |
| SmartShift on/off, mode, sensitivity, scroll force | `CONFIGURATION_TITLE_SMARTSHIFT`, `CONFIGURATION_TITLE_SCROLL_MODE`, `CONFIGURATION_TITLE_SENSITIVITY_VALUE` | `smart_shift_*`, `scroll_force` | Core |
| Thumb wheel direction / speed | `CONFIGURATION_TITLE_THUMBWHEEL_DIRECTION`, `CONFIGURATION_TITLE_THUMBWHEEL_SPEED` | `thumb_wheel_direction`, `thumb_wheel_sensitivity` | Core |
| Swap left/right buttons | `left_right_swapped` | `/mouse/global/swap` | Core |
| Haptic feedback (MX-series haptic) | `haptic_*` keys, `VIBRATION_*`, `CONFIGURATION_TITLE_VIBRATION_*` | `haptic_settings` | Niche (device-specific) |
| Force sensing (MX Master force button), Crown | `/force_sensing_settings/configure`, `/craft_crown_settings/configure` | | Niche |

### 2.2 Buttons and actions catalog

Source: `data/migration/task_id_card_map_osx.json` (233 `taskId` -> `cardId` pairs, V). Labels in `data/strings/en-US.yaml` (`ASSIGNMENT_NAME_*`, 420 keys match `CONFIGURATION_TITLE_|ASSIGNMENT_NAME_`).

Action families present (global presets, V):
- Media: play/pause, next, previous, volume up/down/mute, eject, mic mute (task ids 1-6, 13, 241).
- System: Mission Control (109/150), App Expose (8/158), Launchpad (110/151/179), Show/hide desktop (67), desktop left/right (602/603), Spotlight search (177), Lookup (160), Screen capture (155/223), Emoji and emojis menu (217-221), Dictation (216), Do Not Disturb (242), Switch language (186), Lock (68), Brightness up/down (111/112), Smart zoom (159), Switch apps (197), Switch desktops (301), Tab/app navigation (302/303), Volume control (305).
- Browser / keyboard: copy/paste/cut/undo/redo (801-805, 809/810), Back/Forward (59/61), Zoom in/out (52/54), keyboard shortcut (73, 504 two-way), Open file/folder (69/70), Open application (607), Open ChatGPT / AI overlay (65652/65653), Middle button (58), Advanced click (56/57/605/606), Right click (152), Minimize/Maximize window (611/625), Delete/Home/End/PgUp/PgDn (236-240), Page navigation.
- Gesture button: `card_global_presets_one_of_gesture_button` (tasks 156, 400-404, 500) and Smart Zoom gesture (`hasGestureSmartZoomButton`).
- Thumb wheel presets: `card_global_presets_thumbwheel_do_nothing` (65281), horizontal scroll (405), scroll left/right (63/64).
- App-specific sets (V): Chrome/Safari (tab next/prev/close/reopen/new window), Photoshop (brush size/hardness/opacity, tab nav, save, undo/redo, tools), Excel/Word/PowerPoint (sheet nav, slide nav, text size, find, save), Premiere Pro and Final Cut Pro (timeline navigation, markers, razor/selection tools), Teams and Zoom (toggle mic/camera), WeChat (emoji, screen capture), Line (screen capture, emoji).
- Action types (renderer enum and macro JSON, V): `NONE`, `KEYSTROKE`, `MACROS`, `MACRO_REF`, `APPLICATION`, `SYSTEM`, `SHORTCUT`, `SCROLL`, `SCROLL_LEFT`, `SCROLL_RIGHT`, `RADIAL_MENU`, `TEXT_BLOCK`, `SCREEN_CAPTURE`, `PLUGIN_*`, `FN`, `FN_INVERSION`, `HAPTICS`, `GESTURE_NONE`. The `macro.type` field carries the type. Example in `data/applications.json` cards: `{"attribute":"MACRO_PLAYBACK","macro":{"type":"KEYSTROKE","keystroke":{"code":..,"modifiers":[..],"virtualKeyId":"VK_P"},"actionName":"Cmd + P"}}` (V).

Core vs cloud: the action catalog is core. Smart Actions (macros) and the AI prompt builder are product features beyond the basic remap (see 2.6).

### 2.3 Gesture button and Actions Ring

- Gesture button: `gesture_button`, `gesture_zone`, `gesture_map`, `gesture_list_text` (V, app.min); route `/gesture/configure` (V). Gesture handling in the agent is native (`decomp/gestures/` holds decompiled handlers: 2-finger scroll, 3-finger horizontal swipe, edge swipe). Core.
- Actions Ring (radial menu): `ACTIONS_RING_APPEARANCE_*` (Small/Medium/Large), routes `/radial_menu/{show,event,overlay_scale,overlay_scale_changed,resize_icons,simulate_click}`, `/virtual_device_enumerator/{add,remove}_radial_menu`, `data/overlay/*.json`, `protos/schema/radial_menu.proto` and `protos/logi/protocol/radial_menu.proto` (V). Core for many users (it is the main Logitech "ring" UX).

### 2.4 App-specific profiles

- `applications.json` (23 apps, V): fields `applicationId`, `name`, `version`, `detection` (kind `osxBundle` only, V), `cards` (per-app action cards), `commands`, `categoryColors`, `poster_url`, `profile_url`, `additional_application_data`.
- `defaults/defaults_control_osx.json` and `defaults_slot_osx.json` (V): per-app default assignments for control (button) and slot (gesture/wheel) cards, keyed by `application_id_*` (Photoshop, Excel, Word, PowerPoint, Chrome, Safari, Teams, Zoom, Final Cut, Premiere, plus a global id `420fd454-...`). Core.
- Profile/assignment routes: section 1.7. Profile unification: `/v2/profiles/*`, `/unified_profiles/*` (V, route level).
- Migration from older versions: `data/migration/application_settings_osx.json`, `device_app_table_osx.json`, `task_id_card_map_osx.json` (V).

### 2.5 Flow, Easy-Switch, multi-computer

- Easy-Switch: `DEVICE_DETAILS_*`, `FLOW_*` strings; routes in 1.6 (V). Core for Logitech multi-host users. Keyboard/mouse host switching is mostly firmware, so the app's role is cache and naming (`easy_switch_host_rename`, `easy_switch` state in `settings.db`, key-shape only, V).
- Flow: `DEVICE_DETAILS_FLOW_*`, `FLOW_SETTING_*`, `FLOW_WELCOME_*`, `FLOW_SETUP_*`, `RESET_FLOW_*` (V). Features: link keyboard (`FLOW_SETTING_LINK_KEYBOARD_*`), share clipboard, move cursor to edge / four-corner switching, drag & drop, copy & paste across machines. Core for Flow users; large effort (cross-machine discovery, peer status, `/flow/%s/*`, `flow.proto`). Candidate to drop in v1.

### 2.6 Smart Actions (macros), AI prompt builder

- `MACRO_*`, `MACROS_*`, `MACRO_ONBOARDING_*` (V); routes in 1.7 (V). `macros.db` in the app data folder (V, schema below). Beta flag: `MACRO_JOIN_SMART_ACTIONS_BETA`. AI prompt builder (`/macros/ai_prompt_builder/*`, `ai_prompt_builder*` in `settings.db`, V). AI and backup-restore features are cloud-dependent. Mark as cloud/marketing for v1.

### 2.7 Keyboard

- Backlight (`kb_enable_backlighting`, `kb_backlighting_duration`, `kb_backlighting_brightness_level`, `kb_backlighting_automatic_brightness`), Fn inversion (`fn_inversion`, `isOldFirmwareFnInversion`), F1-F12 standard (`kb_use_f1_f12_as_standard_function`), battery saving (`kb_battery_saving_mode`), keep OS layout (`kb_keep_os_layout`), Fn/caps/num/scroll lock notifications (`/notifications/*`) (V, app.min:124013-124030 and routes). Core for keyboards (mostly firmware, small UI).
- Special keys (`SPECIAL_KEYS_1B04`, `1B06`, `DISABLE_KEYS`) (V, enums).

### 2.8 Battery, notifications, OSD

- Battery: `/battery/*`, `battery_notify` (`interval`, `level`, `keep` — structure, V), `low_battery_notifications_enabled` (V). Core (small).
- Notifications and OSD: `overlay/notification_resources.json`, `osd_resources.json` (V), `/notifications/*`, `/uvc/showmode/notification` (V). Core (small).

### 2.9 Firmware updates (DFU)

- `/updates/*` (app self-update, Squirrel + depot, V), `/dfu/*`, `/firmwareupdate/launch/frontend` (device firmware, V). `firmware.pem`, `logitech-lap-public.pem` in `data/` (V, existence only; not read). Device FW update is a separate concern and is not core for a v1.

### 2.10 Onboarding

- `ONBOARD_WELCOME_*`, `/onboarding` (V). Core only as "device setup" flow.

### 2.11 Account, cloud, backup, marketing, telemetry

- Account: `/accounts/*`, `/identity/oauth2/*`, `ACCOUNT` strings, `Cookies` in app data (not read, V existence only). Cloud/marketing.
- Backup (device and macros): `/backups/*`, `/device/*_settings_restore`, `BETA_OPT_OUT_RESTORE_*`, `MACRO_BACKUP_MODAL_TITLE`. Cloud (verify whether local-only backup exists; ?).
- Offers and marketing: `/offer/*`, `/api/offer/*`, `/star_rating/*`, `/survey*`, `/pipl/status`, `marketplace.logi.com` / `beta-marketplace.logitech.com` (V, main + app). Cloud/marketing; drop.
- Telemetry: `/analytics/*`, `/scarif/*`, `/crash_reporting/*`, `/event_tracing/*`, `device_analytics_config.json` (V, existence). Cloud/marketing; drop (keep crash logs if needed).
- Logi Tune / RightSight / LogiVoice / Presentation / Highlights (webcam, presenter, voice): `RS_*`, `/rightsight/*`, `/logivoice/*`, `/logipresentation/*`, `/logihighlights/*` (V). Out of scope for a mouse/keyboard replacement. Drop.

### 2.12 Settings (general)

- Themes (`SYSTEM_DEFAULT_THEME`, `config.json` key `theme`, V), language (`strings/*.yaml`, 19 locales, V), menu bar/tray (`data/tray/`, `tray_osx.icns`, V), start at login (`/Library/LaunchAgents/com.logi.optionsplus.plist`, V), beta opt-in (`/beta_testing/features`, V).

---

## 3. Per-application profile mechanics

- Data: `data/applications.json` (V, 23 entries). Keys: `applicationId`, `name`, `version`, `detection`, `cards`, `commands`, `categoryColors`, `poster_url`, `profile_url`, `additional_application_data`. Detection is by `osxBundle` (bundle path/ID; the exact sub-fields were not dumped, ?).
- Defaults: `data/defaults/defaults_control_osx.json`, `defaults_slot_osx.json` keyed by `application_id_*`, plus a global id (V).
- Card id scheme: `card_<app>_osx_<action>` e.g. `card_line_osx_emoji`, `card_chrome_osx_tab_next`, `card_global_presets_*` for global (V).
- Foreground switch: agent publishes `/applications/focus/last` and `/application/focus` events; the renderer or agent matches `applicationId` and loads the matching assignment. Exact code path not traced (open question Q3).
- Per-user state: `settings.db` key `applications.applications` (6 entries in this user's blob, structure only, V) and `iconsLocalPathCache` (path -> icon cache, V structure).

---

## 4. Settings persistence

All paths are under `~/Library/Application Support/LogiOptionsPlus` (V existence and structure; no content printed):

| File | Format | Structure (V) |
|---|---|---|
| `settings.db` | SQLite. Tables `data(_id, _date_created, file BLOB)` and `snapshots(_id, _date_created, uuid, label, file BLOB)`. Blob is UTF-8 JSON (first byte `{`). | Flat key -> value JSON. Top-level keys include `applications`, `easy_switch`, `ever_connected_devices`, `battery_notify`, `low_battery_notifications_enabled`, `ai_prompt_builder*`, `dfu/<device>/...`, `battery/<device>/warning_notification`, `analytics_seen_devices_v2`, `crash_reporting`, `iconsLocalPathCache`, `app_permissions_previous`, `first_time_run`, `integration_manager_settings`, `is-global-migrated`. Device-scoped keys embed a device identifier, so do not copy them. |
| `macros.db` | SQLite, same `data`/`snapshots` schema as `settings.db`, JSON blob (V). | Macro store (not dumped). |
| `privacy_settings.db` | SQLite. Tables `privacy_settings(eula, pii_process, pii_transfer, pii_share, update_time)` and `region_history(region, update_time)`, plus views `latest_consent_details`, `latest_region` (V). | Consent and region history. |
| `config.json` | JSON, top key `settings` (V). | UI config. |
| `cc_config.json` | JSON, keys `lastActiveIconLibrary`, `theme` (V). | Control-center UI config. |
| `permissions.json` | JSON, key `macOSPermissionsGranted` (V). | Permission cache. |
| `devio_cache/` | XML files (device ids, `ble_pids.xml`, `paired.xml`) (V existence). | Device discovery cache. |
| `icon_cache/` | per-app icon files (V existence). | Icon cache. |
| `dfu/` | XML (V existence). | FW update state. |

Agent-side: `/Library/Application Support/Logitech.localized/LogiOptionsPlus/` holds `logioptionsplus_agent.app`, `card_presets` (task brief), and the data directory (V from task brief; `loadBackend` plist path V). Protobuf persistence in the agent (`persistence` flag in `mouse.proto Info`, `ModeStatusDevConfig`, and `profiles_v2.proto`) implies device-side persistence (I). Sizes and the device-side store were not inspected.

Open question Q1: is per-device config stored on the device (onboard profiles, `onboard_profiles.proto`) or only in the host files? Needed for the port (on-device vs host-side profile). Not resolved.

Open question Q2: format of the card/profile blobs inside `macros.db` and the agent's `card_presets` (JSON per `data/applications.json`, V).

---

## 5. Launch, lifecycle, permissions

### 5.1 launchd

| Plist | Label | Program | Key settings | Label |
|---|---|---|---|---|
| `/Library/LaunchAgents/com.logi.optionsplus.plist` | `com.logi.cp-dev-mgr` | `/Library/Application Support/Logitech.localized/LogiOptionsPlus/logioptionsplus_agent.app/Contents/MacOS/logioptionsplus_agent` | `RunAtLoad: true`, `KeepAlive: {...}`, `LimitLoadToSessionType: Aqua`, `ProcessType: Interactive`, `AssociatedBundleIdentifiers` | V |
| `/Library/LaunchDaemons/com.logi.optionsplus.updater.plist` | `com.logi.optionsplus.updater` | (updater binary) | `RunAtLoad: true`, `KeepAlive: true` | V |
| `/Applications/logioptionsplus.app/Contents/Resources/loadBackend.sh` | - | `launchctl bootstrap gui/$UID /Library/LaunchAgents/com.logi.optionsplus.plist` | | V |
| `.../unloadBackend.sh` | - | `launchctl bootout gui/$UID ...` | | V |

Agent identity: `data/agent-Info.plist` `CFBundleIdentifier=com.logi.cp-dev-mgr`, `LSUIElement=true` (background, no Dock icon), `NSBluetoothAlwaysUsageDescription`: "Bluetooth is used to communicate with Logi devices." (V).

Main app: `/Applications/logioptionsplus.app` `CFBundleIdentifier=com.logi.optionsplus`, version `2.6.944893`, usage strings `NSBluetoothAlwaysUsageDescription`, `NSBluetoothPeripheralUsageDescription`, `NSCameraUsageDescription`, `NSMicrophoneUsageDescription` (V).

Helpers (V from bundle listing): `logioptionsplus Helper.app`, `Helper (GPU)`, `Helper (Renderer)`, `Helper (Plugin)`, `Electron Framework`, `Squirrel.framework` (self-update), `Mantle`, `ReactiveObjC`. Updater: `logioptionsplus_updater.app` (V from `ps` pattern in main, `asar/deob/main/deobfuscated.js:7049`). Crashpad: `crash_reporting` routes and `Crashpad` not located in listing (?).

Login item: launchd agent with `RunAtLoad` (V). Startup flow in main: `startBackend` (`asar/deob/main/deobfuscated.js:6953`), `isAgentRunning` (`ps -ax | grep logioptionsplus_agent.app`, `:7049`), `checkInstallationIntegrity` (`:7997`, `missing` list), `agent.plist` target copied to `/Library/LaunchAgents/com.logi.optionsplus.plist` (`:7748`) (V).

### 5.2 Permissions (macOS TCC)

Routes `/macos_security/{accessibility,input_monitoring,screen_recording,bluetooth}` and their `/event` variants (V). `permissions.json` `macOSPermissionsGranted` (V existence). Usage reasons seen:
- Accessibility: remapping mouse/keyboard events and sending synthetic keystrokes (`CGEvent`-style injection, `/siminput/*`, `/input/event`) (I, from route names).
- Input Monitoring: reading HID++ and key events (`/input_tracker/*`, `/macos_security/input_monitoring`) (I).
- Screen Recording: `/usr/sbin/screencapture` (V in agent strings) for screen-capture actions; Screen Recording may also be used by the Actions Ring or RightSight (I).
- Bluetooth: `NSBluetoothAlwaysUsageDescription` (V) for HID++ over BLE.
- Camera and Microphone: LogiVoice and RightSight (V usage strings).
- Apple Events (`NSAppleEventsUsageDescription` empty, V).

Caveat: the reasons above are inferred from route names. Confirm with the native binary (decomp/ and `strings`) before listing them as fact.

### 5.3 Processes

- `logioptionsplus` (Electron main), `logioptionsplus Helper*` (renderer, GPU, plugin), `logioptionsplus_agent` (native backend, launchd), `logioptionsplus_updater` (LaunchDaemon), `LogiPluginService` socket (plugin service), `logitech_kiros_logivoice` (voice socket).

---

## 6. Open questions

1. Q1 (blocking for design): is device config held on the device (onboard profiles) or only on the host? `onboard_profiles.proto`, `mouse.proto` `persistence` flag. Verify by reading `decomp/devices/` (pending from coordinator) and `profiles_v2.proto` `Profile.Slots`.
2. Q2: JSON <-> protobuf translation for `payload`. Confirm in the agent: search `decomp/glue/` for JSON parse/serialize of `google.protobuf.Any`.
3. Q3: foreground app detection. Find the agent-side focus tracker (`/applications/focus/last` producer) in `decomp/` or `bin/symbols.txt`.
4. Q4: N() helper identity in the agent-connection module (main bundle `:3671`) versus the plugin-service module (`:3157`).
5. Q5: `CC` socket name `C` (main `:3742`) is not resolved.
6. Q6: exact sub-fields of `applications.json` `detection.osxBundle`, and how the `cards` array feeds the agent (not dumped; structure only).
7. Q7: which features are local-only (Easy-Switch cache, mouse settings, actions) versus cloud-gated (accounts, offers, AI, backups). Needs a runtime or `/accounts/config` review.
8. Q8: Accessibility/Input Monitoring/Screen Recording usage: confirm each permission via native strings and API imports.
9. Q9: `macros.db` and `settings.db` blob schemas (keys and nested layout) were not dumped beyond top-level keys.

## 7. Evidence index (short)

- Transport and framing: `asar/deob/main/deobfuscated.js` lines 3157-3166, 3668-3711, 4810-4990, 8019-8210, 9454-9500; `asar/deob/preload.bundle/deobfuscated.js` 380-393; `asar/deob/app.min/40109.js` 750-765; `asar/deob/app.min/92927.js` 15-16.
- Setting ids and mapping: `asar/deob/app.min/deobfuscated.js` 124007-124014, 124860-124960, 26640-26700, 26770-26800, 164585-164600.
- Protos: `protos/logi/common_protocol/message.proto`, `protos/logi/protocol/mouse.proto`, `profiles_v2.proto`, `flow.proto`, `macros.proto`, `radial_menu.proto`.
- Data: `data/applications.json`, `data/defaults/*.json`, `data/migration/task_id_card_map_osx.json`, `data/strings/en-US.yaml`, `data/agent-Info.plist`.
- Agent: `bin/symbols.txt` lines 82704-82761, 83187-83188, 85880-85901; `strings bin/logioptionsplus_agent.arm64` for routes.
- Bundle and launchd: `/Applications/logioptionsplus.app/Contents/Info.plist`, `/Library/LaunchAgents/com.logi.optionsplus.plist`, `/Library/LaunchDaemons/com.logi.optionsplus.updater.plist`, `/Applications/logioptionsplus.app/Contents/Resources/loadBackend.sh`.
