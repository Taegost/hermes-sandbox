#!/bin/bash
set -e

# Generate only the host key types referenced in sshd_config (RSA + Ed25519)
# Skip if keys already exist and are not writable (e.g., read-only volume mount)
for key_type in rsa ed25519; do
    key_file="/etc/ssh/ssh_host_${key_type}_key"
    if [ ! -f "$key_file" ]; then
        ssh-keygen -t "$key_type" -f "$key_file" -N ""
    elif [ ! -w "$key_file" ]; then
        echo "Warning: $key_file exists but is not writable, skipping generation" >&2
    fi
done

# Start sshd in the foreground as PID 1
# exec ensures sshd receives signals directly for proper container shutdown
exec /usr/sbin/sshd -D
