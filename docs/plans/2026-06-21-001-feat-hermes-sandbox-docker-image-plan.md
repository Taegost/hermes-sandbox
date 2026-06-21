---
title: "feat: Build Hermes Sandbox Docker image"
type: feat
status: active
date: "2026-06-21"
origin: docs/brainstorms/2026-06-21-docker-image-build-requirements.md
---

# feat: Build Hermes Sandbox Docker image

## Summary

Build a Docker image based on `nikolaik/python-nodejs:python3.13-nodejs22` that serves as an SSH backend for Hermes Agent — non-root user `hermes`, passwordless SSH on port 2222, ControlMaster reuse, runtime key mounting. The image includes system packages required by Hermes Agent's shell-based workflow (bash, ripgrep, git, ffmpeg, xz-utils, openssh-server, openssh-client, rsync). Uses Python 3.13 and Node.js 22 to match the official Hermes Docker image.

## Problem Frame

Hermes Agent needs a minimal, secure SSH backend sandbox with Python and Node.js capabilities, but no existing image combines this base with SSH configuration for agent use. This image proves the requirements are understood and provides a reusable artifact for Kubernetes deployment.

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

## Key Technical Decisions

**Non-standard port 2222 over NET_BIND_SERVICE capability.** Allows sshd to bind as non-root without adding capabilities, keeping the container compatible with `cap_drop ALL` and `no-new-privileges` hardening patterns. Kubernetes Service maps external port 22 to container port 2222.

**Runtime key mount over build-time bake.** SSH authorized_keys are mounted as a volume at runtime (e.g., via Kubernetes Secret), not baked into the image. This allows key rotation without rebuilding and keeps keys out of image layers.

**Entrypoint script over sshd as CMD.** An entrypoint script generates host keys before starting sshd, handling the ephemeral-container case where host keys don't persist across restarts. Uses `exec sshd -D` to run sshd in the foreground as PID 1.

**Delete base image user `pn` before creating `hermes`.** The base image creates user `pn` (UID 1000). Removing it first avoids confusion and ensures only the `hermes` user exists for SSH login.

## Open Questions

None — all planning questions resolved.

## Implementation Units

### U1. Dockerfile

- **Goal:** Create the Docker image with all required packages, user setup, and SSH configuration.
- **Requirements:** R1, R2, R3, R4, R5, R6, R7, R9
- **Dependencies:** None
- **Files:** `Dockerfile`
- **Approach:**
  - `FROM nikolaik/python-nodejs:python3.13-nodejs22`
  - `apt-get update && apt-get install -y --no-install-recommends` for all R2 packages
  - Delete the base image's `pn` user (`userdel pn`)
  - Create `hermes` user with UID:GID 10000:10000, home `/home/hermes`, shell `/bin/bash`
  - Create `/home/hermes/.ssh` with mode 700, owned by `hermes`
  - Create `/var/run/sshd` directory
  - Copy `sshd_config` to `/etc/ssh/sshd_config`
  - Copy `entrypoint.sh` to `/entrypoint.sh`, make executable
  - `EXPOSE 2222`
  - `USER hermes`
  - `ENTRYPOINT ["/entrypoint.sh"]`
- **Test scenarios:**
  - Happy path: Build completes successfully with `docker build -t hermes-sandbox .`
  - Happy path: Image contains all R2 packages (`docker run --rm hermes-sandbox which bash rg git ffmpeg xz ssh sshd rsync`)
  - Happy path: User `hermes` exists with UID 10000 (`docker run --rm hermes-sandbox id hermes`)
  - Happy path: No user `pn` exists (`docker run --rm hermes-sandbox id pn` returns non-zero)
  - Edge case: apt cache is cleaned (`docker run --rm hermes-sandbox ls /var/lib/apt/lists/` returns empty)
- **Verification:** Image builds without errors; `docker inspect` shows `User: hermes` and `ExposedPorts: 2222/tcp`.

### U2. SSH Configuration

- **Goal:** Configure sshd for passwordless auth, ControlMaster reuse, and non-standard port.
- **Requirements:** R6, R7, R8, R9
- **Dependencies:** U1
- **Files:** `sshd_config`
- **Approach:**
  - `Port 2222`
  - `PasswordAuthentication no`
  - `ChallengeResponseAuthentication no`
  - `UsePAM no`
  - `AuthorizedKeysFile /home/hermes/.ssh/authorized_keys`
  - `ControlMaster auto`
  - `ControlPath /tmp/ssh-%r@%h:%p`
  - `ControlPersist 5m`
  - `ClientAliveInterval 60`
  - `ClientAliveCountMax 5`
  - `HostKey /etc/ssh/ssh_host_rsa_key`
  - `HostKey /etc/ssh/ssh_host_ed25519_key`
  - `LogLevel INFO`
- **Test scenarios:**
  - Happy path: sshd starts and listens on port 2222 (`docker run -d --name test hermes-sandbox && docker exec test ss -tlnp | grep 2222`)
  - Happy path: Password authentication is rejected (`ssh -o PasswordAuthentication=yes` fails)
  - Edge case: ControlMaster socket is created in `/tmp` after first connection
- **Verification:** sshd binds to port 2222; password auth is disabled; authorized_keys path is `/home/hermes/.ssh/authorized_keys`.

### U3. Entrypoint Script

- **Goal:** Generate SSH host keys at startup and start sshd in the foreground.
- **Requirements:** R10, R11
- **Dependencies:** U1, U2
- **Files:** `entrypoint.sh`
- **Approach:**
  - Check if host keys exist at `/etc/ssh/ssh_host_*`
  - If missing, run `ssh-keygen -A` to generate RSA and Ed25519 host keys
  - `exec /usr/sbin/sshd -D` to run sshd as PID 1 in the foreground
  - Use `exec` so sshd receives signals directly (proper container shutdown)
- **Test scenarios:**
  - Happy path: Container starts and sshd is running (`docker run -d --name test hermes-sandbox && docker exec test pgrep sshd`)
  - Happy path: Host keys are generated on first start (`docker exec test ls /etc/ssh/ssh_host_rsa_key /etc/ssh/ssh_host_ed25519_key`)
  - Edge case: Mounting pre-existing host keys skips generation (`docker run -v /path/to/keys:/etc/ssh hermes-sandbox`)
  - Error path: sshd exits cleanly on `docker stop` (SIGTERM reaches PID 1)
- **Verification:** Container starts sshd; host keys exist; `docker stop` completes within 10 seconds.

### U4. .dockerignore

- **Goal:** Exclude unnecessary files from the Docker build context.
- **Requirements:** None (build optimization)
- **Dependencies:** None
- **Files:** `.dockerignore`
- **Approach:**
  - Exclude `.git/`, `docs/`, `*.md` (except Dockerfile-related), `LICENSE`, `.github/`
  - Keep only `Dockerfile`, `sshd_config`, `entrypoint.sh`
- **Test scenarios:**
  - Test expectation: none — build context exclusion is verified implicitly by build speed and layer count.
- **Verification:** `docker build` context is small; only intended files are copied.

### U5. README Usage Documentation

- **Goal:** Document how to build, run, and deploy the image to Kubernetes.
- **Requirements:** Documentation completeness metric from STRATEGY.md
- **Dependencies:** U1, U2, U3
- **Files:** `README.md`
- **Approach:**
  - Build command: `docker build -t hermes-sandbox .`
  - Run command with SSH key mount: `docker run -d -p 2222:2222 -v /path/to/authorized_keys:/home/hermes/.ssh/authorized_keys:ro hermes-sandbox`
  - Kubernetes deployment example with Secret volume for authorized_keys
  - Note about port mapping (container 2222 → service 22)
  - List of included packages with justification
- **Test scenarios:**
  - Test expectation: none — documentation is verified by readability and accuracy review.
- **Verification:** README covers build, run, and Kubernetes deployment; package list matches Dockerfile.

## Scope Boundaries

- Playwright/Chromium — excluded; not needed for shell-based workflow.
- docker-cli — excluded; Hermes Agent does not run Docker commands inside the sandbox.
- Network policies — Kubernetes-side concern.
- Monitoring and logging — not in scope for v1.
- Multi-architecture builds — not in scope for v1.

### Deferred to Follow-Up Work

- GitHub Actions CI/CD — pattern exists in other repos (per STRATEGY.md), can be duplicated into `.github/workflows/` in a follow-up.
- Host key persistence — users can mount explicit host keys via Kubernetes configs; no image-level persistence needed.

## Sources & Research

- Origin document: `docs/brainstorms/2026-06-21-docker-image-build-requirements.md`
- Product strategy: `STRATEGY.md` — tracks: Image Build & Validation, SSH & Security Configuration
- Base image: [nikolaik/python-nodejs Docker Hub](https://hub.docker.com/r/nikolaik/python-nodejs) — Debian Trixie base, user `pn` (UID 1000), bash default shell, apt-get for package installation
- Version alignment: Official Hermes Docker image uses Python 3.13 and Node.js 22 (`debian:13.4` base). Using `python3.13-nodejs22` matches these versions for maximum task compatibility.
- Hermes Agent docs: [SSH backend configuration](https://hermes-agent.nousresearch.com/docs/user-guide/configuration/) — ControlMaster reuse, persistent bash shell, file sync-back on teardown
- Hardening pattern: [Webnestify writeup](https://webnestify.cloud/insights/cybersecurity-hardening/hermes-agent-deployment/) — cap_drop ALL, no-new-privileges, read-only rootfs
