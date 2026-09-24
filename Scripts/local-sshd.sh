#!/bin/bash
# Starts an unprivileged sshd on 127.0.0.1 for the server tests, with its own keys, and prints the
# exports the tests read once it is listening. It fails, with sshd's log, when sshd cannot listen.
#
#   eval "$(Scripts/local-sshd.sh [port])" && swift test; kill $TRANSFER_TEST_SSHD
#
# TRANSFER_TEST_SSHD is a small watcher, not sshd itself: killing it stops sshd and removes the
# temporary folder that holds the keys, and it removes the folder too when sshd stops on its own.
set -euo pipefail

port="${1:-2222}"
dir="$(mktemp -d -t transfer-sshd)"
trap 'rm -rf "$dir"' EXIT
chmod 700 "$dir"
ssh-keygen -q -t ed25519 -N '' -f "$dir/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$dir/client_key"
cp "$dir/client_key.pub" "$dir/authorized_keys"
chmod 600 "$dir/authorized_keys"
cat > "$dir/sshd_config" <<CONF
Port $port
ListenAddress 127.0.0.1
HostKey $dir/host_key
PidFile none
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile $dir/authorized_keys
StrictModes no
Subsystem sftp /usr/libexec/sftp-server
# Each login's host-key probe connects without authenticating; repeated test runs would trip
# OpenSSH's per-source penalty and have every connection dropped for 15 s or more.
PerSourcePenalties no
CONF

# The watcher runs sshd as its child, so `wait` returns as soon as either sshd exits or the
# watcher is told to stop. It removes the folder only once sshd had been listening: a start
# that failed leaves the log for this script to show. Its output goes nowhere, or
# `$(local-sshd.sh)` would wait on it for as long as sshd runs.
(
    trap 'kill "$sshd" 2>/dev/null || true' TERM HUP
    /usr/sbin/sshd -f "$dir/sshd_config" -D -e < /dev/null 2> "$dir/sshd.log" &
    sshd=$!
    wait "$sshd" || true
    wait "$sshd" 2>/dev/null || true
    if grep -q '^Server listening' "$dir/sshd.log"; then rm -rf "$dir"; fi
) > /dev/null 2>&1 &
watcher=$!

for _ in $(seq 50); do
    grep -q '^Server listening' "$dir/sshd.log" 2>/dev/null && break
    kill -0 "$watcher" 2>/dev/null || break
    sleep 0.1
done
if ! grep -q '^Server listening' "$dir/sshd.log" 2>/dev/null || ! kill -0 "$watcher" 2>/dev/null; then
    kill "$watcher" 2>/dev/null || true
    echo "error: sshd is not listening on 127.0.0.1:$port" >&2
    cat "$dir/sshd.log" >&2 2>/dev/null || true
    exit 1
fi

trap - EXIT
echo "export TRANSFER_TEST_PORT=$port"
echo "export TRANSFER_TEST_IDENTITY=$dir/client_key"
echo "export TRANSFER_TEST_SSHD=$watcher"
