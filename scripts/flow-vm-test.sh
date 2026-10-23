#!/usr/bin/env bash
# End-to-end Flow test between this Mac and a macOS VM (tart), with simulated devices on both sides.
# The VM can't see real HID devices, so each side runs `freespinctl flow-sim`: same mouse unit ID,
# channel 1 here and channel 2 in the VM. The VM pairs with the host, then the mouse and clipboard
# ping-pong. The VM dials the host (not the other way round): a process started from a terminal that
# lacks Local Network permission can't open connections into the VM, while inbound connections work.
#
# FLOW_VM        VM name (default flow-peer; cloned from FLOW_VM_IMAGE if missing)
# MODE           bonjour (default) or direct (the VM dials the host's bridge address, no Bonjour)
# DURATION       seconds of ping-pong (default 20)
# KEEP_VM=1      leave the VM running afterwards
set -euo pipefail
cd "$(dirname "$0")/.."

vm=${FLOW_VM:-flow-peer}
image=${FLOW_VM_IMAGE:-ghcr.io/cirruslabs/macos-sequoia-base:latest}
mode=${MODE:-bonjour}
duration=${DURATION:-20}
port=47100
expect=$((duration / 6))

tart list | awk 'NR > 1 { print $2 }' | grep -qx "$vm" || tart clone "$image" "$vm"
swift build -c release --product freespinctl >/dev/null
bin="$(swift build -c release --show-bin-path)/freespinctl"

started=0
# Not `tart ip`: it answers from the DHCP lease cache even for a stopped VM.
if ! tart list | awk -v vm="$vm" '$2 == vm && $NF == "running" { found = 1 } END { exit !found }'; then
  tart run --no-graphics "$vm" >/dev/null 2>&1 &
  started=1
fi
cleanup() { [ "$started" = 1 ] && [ "${KEEP_VM:-0}" != 1 ] && tart stop "$vm" >/dev/null 2>&1 || true; }
trap cleanup EXIT

ip=$(tart ip --wait 300 "$vm")
for _ in $(seq 150); do tart exec "$vm" true >/dev/null 2>&1 && break; sleep 2; done
tart exec "$vm" true >/dev/null 2>&1 || { echo "FAIL: guest agent in $vm not reachable"; exit 1; }
tart exec -i "$vm" sh -c 'cat > /tmp/freespinctl && chmod +x /tmp/freespinctl' < "$bin"
echo "VM $vm at $ip ($(tart exec "$vm" sw_vers -productVersion)), mode $mode"

logs=$(mktemp -d)
tart exec "$vm" rm -rf /tmp/flow-sim
vm_args=(--name "Flow VM" --dir /tmp/flow-sim --channel 2 --keyboard 0badf00d
         --pair --peer-name "Flow Host" --side left --push left --every 1 --duration $((duration + 4)) --expect "$expect")
host_args=(--name "Flow Host" --dir "$logs/host" --port "$port" --channel 1 --here --keyboard 0badf00d
           --auto-accept --side right --push right --every 1 --copy "clipboard from host"
           --duration "$duration" --expect "$expect")
if [ "$mode" = direct ]; then
  host_ip=$(tart exec "$vm" sh -c "netstat -rn -f inet | awk '/^default/ { print \$2; exit }'")
  host_args+=(--no-bonjour)
  vm_args+=(--no-bonjour --connect "$host_ip:$port")
fi

host_rc=0
"$bin" flow-sim "${host_args[@]}" >"$logs/host.log" 2>&1 &
host_job=$!
sleep 1
vm_rc=0
tart exec "$vm" /tmp/freespinctl flow-sim "${vm_args[@]}" >"$logs/vm.log" 2>&1 || vm_rc=$?
wait "$host_job" || host_rc=$?

echo "--- host ($host_rc)"; cat "$logs/host.log"
echo "--- vm ($vm_rc)"; cat "$logs/vm.log"
grep -q 'clipboard received.*clipboard from host' "$logs/vm.log" || { echo "FAIL: clipboard did not reach the VM"; exit 1; }
if [ "$host_rc" = 0 ] && [ "$vm_rc" = 0 ]; then
  echo "PASS: Flow ping-pong between host and VM ($mode)"
else
  echo "FAIL: host=$host_rc vm=$vm_rc"
  exit 1
fi
