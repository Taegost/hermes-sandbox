---
title: "Container sshd configuration lessons for non-root SSH backends"
date: 2026-06-21
category: docs/solutions/tooling-decisions
module: hermes-agent-ssh-backend
problem_type: tooling_decision
component: tooling
severity: medium
applies_when:
  - "Building SSH server containers based on nikolaik/python-nodejs or similar Debian-based images"
  - "Configuring sshd for key-only authentication with mounted authorized_keys"
  - "Running sshd in containers with cap_drop ALL or no-new-privileges hardening"
tags:
  - sshd
  - openssh
  - docker
  - container-security
  - kubernetes
  - ssh-config
  - usepam
  - strictmodes
---

# Container sshd configuration lessons for non-root SSH backends

## Context

When building a Docker image that runs `sshd` as a service for an AI agent sandbox, several assumptions from standard Docker practices broke down. The base image is `nikolaik/python-nodejs:python3.13-nodejs22` (Debian Trixie), and the container must accept SSH connections on port 2222 with key-only authentication. The initial implementation plan contained five incorrect assumptions about how OpenSSH's sshd operates in a containerized environment. Each produced a distinct failure mode during build or runtime testing.

## Guidance

### 1. ControlMaster/ControlPath/ControlPersist are client-side options, not server directives

**What went wrong:** The original `sshd_config` included:

```sshd_config
# WRONG — these are client-side options, sshd rejects them
ControlMaster auto
ControlPath /tmp/ssh-%r@%h:%p
ControlPersist 5m
```

sshd refused to start:

```
/etc/ssh/sshd_config: line 13: Bad configuration option: ControlMaster
/etc/ssh/sshd_config: line 14: Bad configuration option: ControlPath
/etc/ssh/sshd_config: line 15: Bad configuration option: ControlPersist
sshd_config: terminating, 3 bad configuration options
```

**What is correct:** `ControlMaster`, `ControlPath`, and `ControlPersist` are **SSH client options** that control connection multiplexing on the connecting side. The SSH server (sshd) supports multiplexed connections transparently without any special configuration — it is the *client* that must be told to reuse a control socket. These directives belong in `~/.ssh/config` on the machine initiating the SSH connection, not in the server's configuration.

The server-side equivalents for keepalive are `ClientAliveInterval` and `ClientAliveCountMax`, which prevent idle disconnects.

### 2. sshd cannot run as a non-root user

**What went wrong:** The original plan specified `USER hermes` before the `ENTRYPOINT`, meaning sshd would run as UID 10000. This failed immediately:

```
Unable to load host key: /etc/ssh/ssh_host_rsa_key
Unable to load host key: /etc/ssh/ssh_host_ed25519_key
sshd: no hostkeys available — exiting.
```

sshd needs root privileges for two things:

- **Reading host keys**: Host key files are owned by root with mode `600`. A non-root sshd process cannot read them.
- **Privilege separation**: sshd uses a privilege separation model where it starts as root, pre-authenticates in a chroot, then drops to the authenticated user's UID. This model requires initial root access.

**What is correct:** sshd runs as root but drops privileges to the authenticated user's UID after authentication. Security is enforced through `sshd_config` (key-only auth, no passwords), not through running the sshd process itself as non-root.

### 3. Host keys should be generated at build time

**What went wrong:** The original plan specified runtime host key generation in `entrypoint.sh`. When the container ran as `USER hermes`, `ssh-keygen -A` also failed because it requires root to write to `/etc/ssh/`.

Even after fixing the user issue, generating host keys at every container start is unnecessary overhead and creates different host keys on each restart (breaking `known_hosts` on connecting clients).

**What is correct:** `ssh-keygen -A` runs during `docker build` when the build context has root privileges. The keys are baked into the image layer. Users who need key consistency across restarts can mount explicit host keys via Kubernetes config maps.

### 4. UsePAM yes is required for user validation on Debian Trixie

**What went wrong:** The original plan specified `UsePAM no`. With OpenSSH 10.0 on Debian Trixie, setting `UsePAM no` caused all SSH login attempts to fail:

```
debug2: userauth_pubkey: invalid user hermes querying public key ssh-ed25519 ...
debug2: userauth_pubkey: disabled because of invalid user
Connection closed by invalid user hermes [preauth]
```

Investigation confirmed the `hermes` user existed correctly (verified via `getpwnam()` in Python and `id hermes` at the shell), yet sshd still rejected it.

**What is correct:** On Debian-based systems, `UsePAM yes` is required for sshd to properly resolve and validate local users. The PAM stack handles user validation that sshd relies on. Critically, `UsePAM yes` combined with `PasswordAuthentication no` and `ChallengeResponseAuthentication no` still enforces key-only authentication — PAM handles user validation while passwords remain disabled.

**When UsePAM no is appropriate:** Only on non-PAM systems (some BSDs, minimal Alpine-based images) where user resolution does not depend on PAM. On any Debian, Ubuntu, or RHEL-based image, assume `UsePAM yes` is required.

### 5. StrictModes no is required for mounted authorized_keys

**What went wrong:** When the `authorized_keys` file is mounted from a Kubernetes Secret or Docker volume, its UID ownership reflects the host or the volume provisioner, not the container's `hermes` user (UID 10000). With `StrictModes yes` (the default), sshd checks that `authorized_keys` is owned by the authenticated user and rejects it otherwise:

```
Authentication refused: bad ownership or modes for file /home/hermes/.ssh/authorized_keys
```

**What is correct:** Set `StrictModes no` when authorized_keys files are mounted from external sources. This relaxes sshd's file ownership checks while still requiring the key itself to be valid.

**When StrictModes yes is appropriate:** When the `authorized_keys` file is baked into the image or managed entirely within the container where UID ownership can be guaranteed.

## Why This Matters

1. **sshd is not a generic TCP service** — it has deep integration with the OS user model, PAM, and privilege separation. Treating it like a stateless HTTP server ignores fundamental architectural constraints.

2. **Client vs. server option confusion is a persistent source of bugs** — SSH documentation lists both client and server options in the same man pages, making it easy to place client directives in `sshd_config`.

3. **Container UID mismatches with mounted secrets are the norm** — Kubernetes Secrets, Docker volumes, and host-mounted files almost never match the container user's UID.

4. **PAM is a hidden dependency on Debian** — Disabling PAM breaks sshd's ability to look up local users even when they exist in `/etc/passwd`.

## When to Apply

- Building any Docker image that runs `sshd` as the primary service
- Using Debian or Ubuntu base images with OpenSSH 8.2+
- Mounting SSH keys or authorized_keys from Kubernetes Secrets or Docker volumes
- Deploying sshd containers with `cap_drop ALL` or `no-new-privileges`
- Configuring ControlMaster for AI agent SSH backends (the client-side setting goes in the agent's SSH config, not the server)

## Examples

### Corrected sshd_config

```sshd_config
Port 2222
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
AuthorizedKeysFile /home/hermes/.ssh/authorized_keys
StrictModes no
ClientAliveInterval 60
ClientAliveCountMax 5
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
LogLevel INFO
```

### Corrected Dockerfile (relevant sections)

```dockerfile
# Generate SSH host keys at build time
RUN ssh-keygen -A

# Copy SSH configuration
COPY sshd_config /etc/ssh/sshd_config

EXPOSE 2222

# sshd runs as root (drops privileges after auth).
# Security is enforced by sshd_config: key-only auth, no passwords.
ENTRYPOINT ["/entrypoint.sh"]
```

### Corrected entrypoint.sh

```bash
#!/bin/bash
set -e

# Start sshd in the foreground as PID 1
# exec ensures sshd receives signals directly for proper container shutdown
exec /usr/sbin/sshd -D
```

## Related

- `docs/solutions/tooling-decisions/hermes-sandbox-base-image-version.md` — base image version alignment decision
- `docs/plans/2026-06-21-001-feat-hermes-sandbox-docker-image-plan.md` — the implementation plan that contained the original (incorrect) specifications
- `docs/brainstorms/2026-06-21-docker-image-build-requirements.md` — requirements document with R6-R11 covering SSH configuration
