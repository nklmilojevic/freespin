# Changelog

## v0.3.0 - 2026-10-23

This release adds Flow, which moves your mouse between Macs. It also adds a headless daemon, automatic updates, and signed releases.

### New features

- Add Flow. When you push the pointer past a screen edge, the Easy-Switch mouse moves to the other Mac. Linked Logitech keyboards and the clipboard follow. Flow works on the local network only. Pair two Macs with a six-digit code.
- Add a sleeping keyboard follow. A keyboard that is asleep when the mouse leaves now follows the mouse when it wakes.
- Add `freespinctl hosts` to show the host channels of your devices. Add `freespinctl flow-sim` to test Flow without real devices.
- Add `freespinctl daemon`. It runs Freespin in the background and reads a JSON config file. It reloads the config on `SIGHUP` and gives the wheel back to macOS on `SIGTERM`.
- Add a Nix flake and a home-manager module. The module checks your config when it builds.
- Add automatic updates with Sparkle. Use the gear menu to check for updates or to turn on automatic checks.
- Add signed and notarized releases, so macOS accepts the app and the CLI.

### Fixes

- Fix the keyboard follow. The keyboard stays on this Mac when you use the pointer here, or when you switch the mouse back with its Easy-Switch button.
- Fix Flow reconnection. Flow now tries again to connect to a paired Mac when the link drops or a connection attempt fails.
- Fix the clipboard. An empty clipboard now carries over, so the other Mac does not paste old data.
- Fix the Flow sidebar. The Computers section works on a Mac that has no Logitech devices.
- Fix the daemon config. A device entry now adds to the per-app settings from `default` and does not replace them.
- Fix the daemon control and shutdown. A second daemon cannot start on the same state directory. The daemon handles `SIGTERM` and `SIGINT` while it waits for permissions.
- Fix a failed wheel-mode write. The daemon now tries again on the next apply or reload.
- Fix `freespinctl list`. It now prints the key of each device.

### Other changes

- Remove the reverse-engineering wording from the README.

## v0.2.0 - 2026-10-23

This release lets Freespin run in the background without a Dock icon. You can close the window and the app keeps control of the mouse.

### New features

- Freespin runs as a background app with no Dock icon. When you close the window, scrolling, buttons, and the receiver keep working. Open Freespin again to show the window.
- A new gear menu in the toolbar has `Quit Freespin` and `Open at Login`. `Quit Freespin` restores native macOS scrolling. When Freespin starts at login, it starts hidden.

### Other changes

- Local builds that use a Developer ID identity now sign the app, `freespinctl`, and the DMG with the hardened runtime and a secure timestamp. You can then notarize these builds.

## v0.1.0 - 2026-10-23

This release gives macOS users a native app to control Logitech mice. It replaces Logi Options+ and supports Logi Bolt and Unifying receivers.

### New features

- Add the Freespin app for macOS. It controls Logitech HID++ mice and gives the wheel, thumb wheel, SmartShift, DPI, button remapping, gesture button, Actions Ring, per-app profiles, and low-battery notifications in one place.
- Add the `freespinctl` command-line tool. It lets the user control Freespin from a terminal.
- Add support for Logi Bolt and Unifying receivers. Devices that connect to or disconnect from a receiver appear in the app at once.
- Add pairing and unpairing for receivers, in the app and with `freespinctl receivers`, `freespinctl pair`, and `freespinctl unpair`. The pairing sheet highlights the next button to press.
- Add a release DMG and a `freespinctl` tarball with checksums for each version tag. The user can install Freespin from these files.

### Fixes

- Fix the handling of error responses from receivers. Freespin now shows a neutral device name until the device gives its real name.

### Other changes

- Add a README section about Bolt pairing and a note about the G502 X mouse.
