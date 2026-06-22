#!/bin/bash
set -e

# Generate host keys if missing (first run, or when /etc/ssh is volume-mounted)
ssh-keygen -A

# Start sshd in the foreground as PID 1
# exec ensures sshd receives signals directly for proper container shutdown
exec /usr/sbin/sshd -D
