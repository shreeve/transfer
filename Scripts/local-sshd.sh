#!/bin/bash
# Starts an unprivileged sshd on 127.0.0.1 for the server tests, with its own keys.
# Usage: eval "$(Scripts/local-sshd.sh)" then `swift test`. Stop it with: kill $TRANSFER_TEST_SSHD
set -euo pipefail

port="${1:-2222}"
dir="$(mktemp -d -t transfer-sshd)"
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
CONF
/usr/sbin/sshd -f "$dir/sshd_config" -D -e > "$dir/sshd.log" 2>&1 &
echo "export TRANSFER_TEST_PORT=$port"
echo "export TRANSFER_TEST_IDENTITY=$dir/client_key"
echo "export TRANSFER_TEST_SSHD=$!"
