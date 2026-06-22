---
date: "2026-06-21"
topic: docker-image-build
---

# Docker Image Build Requirements

## Summary

A Docker image based on `nikolaik/python-nodejs:python3.13-nodejs22` serving as an SSH backend for Hermes Agent — persistent bash shell, ControlMaster reuse, skills/credentials rsynced in before commands, files rsynced back on teardown. Runs as non-root user `hermes`, accepts SSH on port 2222, uses runtime key mounting for passwordless auth. Uses Python 3.13 and Node.js 22 to match the official Hermes Docker image.

## Problem Frame

Hermes Agent needs a minimal, secure SSH backend sandbox with Python and Node.js capabilities, but the exact requirements are unclear and no good documentation exists for this specific combination. The challenge is both discovering what's actually needed and documenting the validated solution. This image is the first deliverable — a working, auditable Dockerfile that proves the requirements are understood.

## Key Decisions

**Non-standard port 2222.** Avoids conflicts with host sshd on port 22. Kubernetes Service maps external port 22 to container port 2222. sshd runs as root for privilege separation (not for port binding — port 2222 is non-privileged).

**Runtime key mount over build-time bake.** SSH authorized_keys are mounted as a volume at runtime (e.g., via Kubernetes Secret), not baked into the image. This allows key rotation without rebuilding the image and keeps keys out of image layers.

**SSH host keys generated at startup.** The entrypoint script generates host keys on each container start. Users can also mount an explicit host key via Kubernetes configs for consistency across restarts.

## Requirements

### Image & Packages

- R1. Base image is `nikolaik/python-nodejs:python3.13-nodejs22`.
- R2. Install system packages: `bash`, `ripgrep`, `git`, `ffmpeg`, `xz-utils`, `openssh-server`, `openssh-client`, `rsync`.
- R3. Do not install Playwright/Chromium or docker-cli.

### User & Permissions

- R4. Create non-root user `hermes` with UID:GID `10000:10000`.
- R5. User has a writable home directory at `/home/hermes`.

### SSH Configuration

- R6. sshd listens on port 2222.
- R7. Passwordless SSH authentication — no password prompts, key-based only.
- R8. `authorized_keys` is read from `/home/hermes/.ssh/authorized_keys` (mounted at runtime).
- R9. ControlMaster connection reuse enabled with 5-minute keepalive interval.
- R10. SSH host keys generated at startup by the entrypoint script.

### Container Behavior

- R11. Entrypoint generates SSH host keys (if not already present) and starts sshd in the foreground.
- R12. Container accepts only incoming SSH connections on port 2222.
- R13. Container allows all outgoing network traffic.

## Scope Boundaries

- Playwright/Chromium — excluded; not needed for Hermes Agent's shell-based workflow.
- docker-cli — excluded; Hermes Agent does not run Docker commands inside the sandbox.
- Network policies — Kubernetes-side concern, not part of the Docker image.
- Monitoring and logging — not in scope for v1.
- Multi-architecture builds — optional; provided by the shared workflow at no extra configuration cost.
