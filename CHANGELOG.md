# Changelog

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
