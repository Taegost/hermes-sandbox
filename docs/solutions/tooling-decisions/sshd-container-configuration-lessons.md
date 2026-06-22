---
title: "Container sshd configuration lessons for non-root SSH backends"
date: 2026-06-21
last_updated: 2026-06-22
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
  - permitrootlogin
  - host-keys
  - authorizedkeysfile
---

# Container sshd configuration lessons for non-root SSH backends

## Context

When building a Docker image that runs `sshd` as a service for an AI agent sandbox, several assumptions from standard Docker practices broke down. The base image is `nikolaik/python-nodejs:python3.13-nodejs22` (Debian Trixie), and the container must accept SSH connections on port 2222 with key-only authentication. The initial implementation plan contained incorrect assumptions about how OpenSSH's sshd operates in a containerized environment. Each produced a distinct failure mode during build or runtime testing.

A subsequent security review identified additional hardening gaps: baked-in host keys, missing `PermitRootLogin no`, an absolute `AuthorizedKeysFile` path that extended the auth surface to all system users, and overly broad key generation. These findings are documented in the security hardening section below.

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

### 3. Host keys must be generated at runtime, not baked into the image

**What went wrong:** The original plan specified runtime host key generation in `entrypoint.sh`. When the container ran as `USER hermes`, `ssh-keygen -A` also failed because it requires root to write to `/etc/ssh/`.

The initial fix moved key generation to `docker build` (`RUN ssh-keygen -A`), which solved the functional problem but created a security vulnerability: private host keys become permanent in the image layer. Anyone with registry access or `docker save` can extract them, enabling MITM attacks against all containers from that image.

Additionally, the `openssh-server` package postinst script generates host keys during `apt-get install`, so even removing `RUN ssh-keygen -A` from the Dockerfile was insufficient — the package installer already created keys.

**What is correct:** Generate host keys at runtime in `entrypoint.sh`, but only the specific types referenced in `sshd_config` (RSA and Ed25519). Remove keys created by the package postinst script during the build. Use existence and writability checks to handle read-only volume mounts gracefully:

```dockerfile
RUN apt-get install -y openssh-server && \
    rm -f /etc/ssh/ssh_host_* && \
    rm -rf /var/lib/apt/lists/*
```

```bash
# In entrypoint.sh — generate only required key types
for key_type in rsa ed25519; do
    key_file="/etc/ssh/ssh_host_${key_type}_key"
    if [ ! -f "$key_file" ]; then
        ssh-keygen -t "$key_type" -f "$key_file" -N ""
    elif [ ! -w "$key_file" ]; then
        echo "Warning: $key_file exists but is not writable, skipping generation" >&2
    fi
done
```

Never use `ssh-keygen -A` in production containers — it generates all supported types including deprecated DSA and unnecessary ECDSA. Users who need key consistency across restarts can mount explicit host keys at `/etc/ssh/`.

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

```text
Authentication refused: bad ownership or modes for file /home/hermes/.ssh/authorized_keys
```

**What is correct:** Set `StrictModes no` when authorized_keys files are mounted from external sources. This relaxes sshd's file ownership checks while still requiring the key itself to be valid.

**Why StrictModes yes is not an option:** Docker `-v` mounts retain the host file's UID (e.g., uid 1000 on the host), which fails sshd's ownership checks. K8s Secret `subPath` mounts create files owned by root (uid 0) with mode 0600, which would satisfy `StrictModes yes`. However, since this image must support both Docker and Kubernetes deployments, `StrictModes no` is required. Docker compatibility is a project requirement.

**When StrictModes yes is appropriate:** When the `authorized_keys` file is baked into the image, managed entirely within the container where UID ownership can be guaranteed, or when only K8s Secret `subPath` mounts are used.

### 6. PermitRootLogin no is required even with key-only auth

**What went wrong:** The original `sshd_config` did not set `PermitRootLogin`. OpenSSH defaults to `prohibit-password`, which still allows key-based root login. Since the `AuthorizedKeysFile` was an absolute path (`/home/hermes/.ssh/authorized_keys`), any key in the mounted file could authenticate as root.

**What is correct:** Always set `PermitRootLogin no` explicitly. The default `prohibit-password` is a common misconfiguration in containerized SSH setups where operators assume key-only auth is sufficient.

### 7. AuthorizedKeysFile must use %h for per-user scoping

**What went wrong:** The original config used an absolute path:

```sshd_config
AuthorizedKeysFile /home/hermes/.ssh/authorized_keys
```

This means all system users (including root) check the same key file. Any valid user account with a matching key can authenticate, expanding the auth surface beyond the intended `hermes` user.

**What is correct:** Use the `%h` token to scope to each user's home directory:

```sshd_config
AuthorizedKeysFile %h/.ssh/authorized_keys
```

This ensures only keys in a user's own `.ssh` directory are checked, preventing cross-user authentication.

### 8. Package postinst scripts generate secrets during install

**What went wrong:** Removing `RUN ssh-keygen -A` from the Dockerfile was necessary but insufficient. The `openssh-server` package's postinst script runs `ssh-keygen -A` during `apt-get install`, so host keys were still baked into the image.

**What is correct:** Always clean up secrets generated by package installers in the same `RUN` layer:

```dockerfile
RUN apt-get install -y openssh-server && \
    rm -f /etc/ssh/ssh_host_* && \
    rm -rf /var/lib/apt/lists/*
```

Apply the same pattern for any package that writes secrets during installation (e.g., `rm -f /etc/ssl/private/*` after TLS packages).

## Why This Matters

1. **sshd is not a generic TCP service** — it has deep integration with the OS user model, PAM, and privilege separation. Treating it like a stateless HTTP server ignores fundamental architectural constraints.

2. **Client vs. server option confusion is a persistent source of bugs** — SSH documentation lists both client and server options in the same man pages, making it easy to place client directives in `sshd_config`.

3. **Container UID mismatches with mounted secrets are the norm** — Kubernetes Secrets, Docker volumes, and host-mounted files almost never match the container user's UID.

4. **PAM is a hidden dependency on Debian** — Disabling PAM breaks sshd's ability to look up local users even when they exist in `/etc/passwd`.

5. **Baked-in secrets are extractable from image layers** — Private keys, certificates, and tokens embedded in image layers can be extracted via `docker save` or registry access. Generate secrets at runtime, clean up after package installers.

6. **OpenSSH defaults are not safe defaults** — `PermitRootLogin prohibit-password` allows key-based root login. `AuthorizedKeysFile` without `%h` extends auth to all users. Always set these explicitly.

## When to Apply

- Building any Docker image that runs `sshd` as the primary service
- Using Debian or Ubuntu base images with OpenSSH 8.2+
- Mounting SSH keys or authorized_keys from Kubernetes Secrets or Docker volumes
- Deploying sshd containers with `cap_drop ALL` or `no-new-privileges`
- Configuring ControlMaster for AI agent SSH backends (the client-side setting goes in the agent's SSH config, not the server)
- Installing packages that generate secrets during postinst (openssh-server, openssl, etc.)
- Configuring SSH authentication in multi-user containers

## Examples

### Corrected sshd_config

```sshd_config
Port 2222
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
PermitRootLogin no

# Key-based authentication only — %h scopes to each user's home directory
AuthorizedKeysFile %h/.ssh/authorized_keys
StrictModes no

ClientAliveInterval 60
ClientAliveCountMax 5

# Host keys — generated at runtime by entrypoint.sh (not baked into image)
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

LogLevel INFO
```

### Corrected Dockerfile (relevant sections)

```dockerfile
RUN apt-get update && \
    apt-get install -y --no-install-recommends openssh-server && \
    rm -f /etc/ssh/ssh_host_* && \
    rm -rf /var/lib/apt/lists/*

# ... (user setup, sshd privilege separation directory) ...

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 2222

# sshd runs as root (drops privileges after auth).
# Security is enforced by sshd_config: key-only auth, no passwords.
ENTRYPOINT ["/entrypoint.sh"]
```

### Corrected entrypoint.sh

```bash
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
```

## Related

- `docs/solutions/tooling-decisions/hermes-sandbox-base-image-version.md` — base image version alignment decision
- `docs/plans/2026-06-21-001-feat-hermes-sandbox-docker-image-plan.md` — the implementation plan that contained the original (incorrect) specifications; superseded by actual implementation
- `docs/brainstorms/2026-06-21-docker-image-build-requirements.md` — requirements document with R6-R11 covering SSH configuration
