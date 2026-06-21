#!/bin/bash
set -e

# Start sshd in the foreground as PID 1
# exec ensures sshd receives signals directly for proper container shutdown
exec /usr/sbin/sshd -D
