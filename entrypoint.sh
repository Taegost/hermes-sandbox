#!/bin/bash
set -e

# Generate only the host key types referenced in sshd_config (RSA + Ed25519)
# If keys already exist (e.g., mounted from a Kubernetes Secret), use them as-is.
# sshd will fail with a clear error if a key is corrupt or unreadable.
for key_type in rsa ed25519; do
    key_file="/etc/ssh/ssh_host_${key_type}_key"
    if [ ! -f "$key_file" ]; then
        if ! ssh-keygen -t "$key_type" -f "$key_file" -N "" 2>/dev/null; then
            echo "Error: Cannot generate $key_file — /etc/ssh may be read-only. Mount a writable volume or pre-populate host keys via a Kubernetes Secret." >&2
            exit 1
        fi
    elif [ ! -w "$key_file" ]; then
        echo "Info: $key_file exists but is not writable — using existing key (e.g., mounted from Kubernetes Secret)." >&2
    fi
done

# Start sshd in the foreground as PID 1
# exec ensures sshd receives signals directly for proper container shutdown
exec /usr/sbin/sshd -D -e
