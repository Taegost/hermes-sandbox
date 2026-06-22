---
title: "Container sshd configuration lessons for non-root SSH backends"
date: 2026-06-21
last_updated: 2026-06-22
last_updated_note: "Added lessons 9-14 from PR review rounds 4-6: AllowUsers, minimal capabilities, digest pinning, error preservation, id vs getent, entrypoint key generation logic"
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
  - capabilities
  - supply-chain
  - allowusers
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

### 9. AllowUsers restricts SSH to intended users only

**What went wrong:** Without `AllowUsers hermes`, sshd authenticates any unix account that presents a valid public key. Base images include standard system accounts (e.g., `www-data`, `daemon`) with valid shells. `PermitRootLogin no` blocks root but not these other accounts.

**What is correct:** Add `AllowUsers hermes` to `sshd_config` after `PermitRootLogin no`. This makes the allowed-user list explicit and independent of which accounts happen to exist in the image.

### 10. Minimal capabilities for sshd containers

**What went wrong:** The Kubernetes Deployment example initially used `capabilities: drop: ["ALL"]` without adding back the capabilities sshd needs. Later, the capabilities block was removed entirely, leaving the container with full default Linux capabilities.

**What is correct:** Use a minimal drop-all + add-back pattern. sshd requires `SETUID`, `SETGID`, and `SYS_CHROOT` for privilege separation. PAM requires `CHOWN` and `AUDIT_WRITE`. `DAC_READ_SEARCH` is unnecessary for key-only auth — sshd reads `authorized_keys` after dropping to the authenticated user's UID.

```yaml
securityContext:
  capabilities:
    drop: ["ALL"]
    add:
      - SETUID
      - SETGID
      - SYS_CHROOT
      - CHOWN
      - AUDIT_WRITE
  readOnlyRootFilesystem: false
  allowPrivilegeEscalation: true
```

**Why allowPrivilegeEscalation: true is required:** sshd calls `setuid()` to drop from root to the authenticated user. `no_new_privs` blocks this call, and every SSH session fails.

### 11. Pin base images to digests for supply chain security

**What went wrong:** `FROM nikolaik/python-nodejs:python3.13-nodejs22` references a mutable tag. If the upstream image is updated or compromised, the next `docker build` silently pulls the new image.

**What is correct:** Pin the base image to its current digest:

```dockerfile
FROM nikolaik/python-nodejs:python3.13-nodejs22@sha256:<digest>
```

Keep the tag for human readability alongside the digest. Get the current digest with:

```bash
docker pull nikolaik/python-nodejs:python3.13-nodejs22
docker inspect nikolaik/python-nodejs:python3.13-nodejs22 --format='{{index .RepoDigests 0}}'
```

### 12. Preserve error output in entrypoint scripts

**What went wrong:** `ssh-keygen ... 2>/dev/null` discards all stderr before printing a hardcoded error message. If `ssh-keygen` fails for any reason other than read-only filesystem (disk quota, corrupted binary, unsupported key type), the actual error is gone and the operator diagnoses the wrong problem.

**What is correct:** Let ssh-keygen's error output appear on stderr naturally, then append context-level guidance:

```bash
if ! ssh-keygen -t "$key_type" -f "$key_file" -N ""; then
    echo "Error: Cannot generate $key_file. Check that /etc/ssh is writable, disk is not full, and the key type is supported." >&2
    exit 1
fi
```

### 13. Use `id` instead of `getent` for user existence checks in Dockerfiles

**What went wrong:** `getent passwd pn` depends on NSS (Name Service Switch). In CI environments with transient NSS issues or cross-platform `docker buildx` contexts, `getent` can return non-zero even when the user exists in `/etc/passwd`.

**What is correct:** Use `id pn` instead — it's a POSIX utility that reads `/etc/passwd` directly without NSS dependency:

```dockerfile
RUN if id pn > /dev/null 2>&1; then userdel -r pn || true; fi
```

### 14. Entrypoint key generation: handle existing vs missing keys differently

**What went wrong:** The entrypoint script used `exit 1` when a host key file existed but was not writable. K8s Secret mounts are read-only by default, so mounting pre-populated host keys triggered the error — the exact scenario the error message recommended.

**What is correct:** Treat existing keys (read-only or not) as valid — sshd will load them and fail with a clear error if they're corrupt. Only error when keys are missing and cannot be generated (read-only filesystem):

```bash
for key_type in rsa ed25519; do
    key_file="/etc/ssh/ssh_host_${key_type}_key"
    if [ ! -f "$key_file" ]; then
        if ! ssh-keygen -t "$key_type" -f "$key_file" -N ""; then
            echo "Error: Cannot generate $key_file. Check that /etc/ssh is writable." >&2
            exit 1
        fi
    elif [ ! -w "$key_file" ]; then
        echo "Info: $key_file exists but is not writable — using existing key." >&2
    fi
done
```

## Why This Matters

1. **sshd is not a generic TCP service** — it has deep integration with the OS user model, PAM, and privilege separation. Treating it like a stateless HTTP server ignores fundamental architectural constraints.

2. **Client vs. server option confusion is a persistent source of bugs** — SSH documentation lists both client and server options in the same man pages, making it easy to place client directives in `sshd_config`.

3. **Container UID mismatches with mounted secrets are the norm** — Kubernetes Secrets, Docker volumes, and host-mounted files almost never match the container user's UID.

4. **PAM is a hidden dependency on Debian** — Disabling PAM breaks sshd's ability to look up local users even when they exist in `/etc/passwd`.

5. **Baked-in secrets are extractable from image layers** — Private keys, certificates, and tokens embedded in image layers can be extracted via `docker save` or registry access. Generate secrets at runtime, clean up after package installers.

6. **OpenSSH defaults are not safe defaults** — `PermitRootLogin prohibit-password` allows key-based root login. `AuthorizedKeysFile` without `%h` extends auth to all users. Always set these explicitly.

7. **Docker and Kubernetes have different mount semantics** — Docker `-v` mounts retain host UID ownership; K8s Secret `subPath` mounts create root-owned files. Configuration that works in one may fail in the other. When supporting both, choose the more permissive option.

8. **Capabilities are not all-or-nothing** — `drop: ["ALL"]` without adding back needed caps breaks sshd. Removing caps entirely grants unnecessary privileges. Use the minimal set: `SETUID`, `SETGID`, `SYS_CHROOT`, `CHOWN`, `AUDIT_WRITE`.

9. **Supply chain security requires digest pinning** — Mutable image tags can be overwritten. Pin base images to digests and keep tags for readability.

## When to Apply

- Building any Docker image that runs `sshd` as the primary service
- Using Debian or Ubuntu base images with OpenSSH 8.2+
- Mounting SSH keys or authorized_keys from Kubernetes Secrets or Docker volumes
- Deploying sshd containers with `cap_drop ALL` or `no-new-privileges`
- Configuring ControlMaster for AI agent SSH backends (the client-side setting goes in the agent's SSH config, not the server)
- Installing packages that generate secrets during postinst (openssh-server, openssl, etc.)
- Configuring SSH authentication in multi-user containers
- Writing Kubernetes Deployment YAML for sshd containers (capabilities, seccomp, privilege escalation)
- Pinning base images in Dockerfiles for supply chain security

## Examples

### Corrected sshd_config

```sshd_config
Port 2222
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
PermitRootLogin no
AllowUsers hermes

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
FROM nikolaik/python-nodejs:python3.13-nodejs22@sha256:<digest>

RUN apt-get update && \
    apt-get install -y --no-install-recommends openssh-server && \
    rm -f /etc/ssh/ssh_host_* && \
    rm -rf /var/lib/apt/lists/*

# Remove base image user
RUN if id pn > /dev/null 2>&1; then userdel -r pn || true; fi

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
# If keys already exist (e.g., mounted from a Kubernetes Secret), use them as-is.
# sshd will fail with a clear error if a key is corrupt or unreadable.
for key_type in rsa ed25519; do
    key_file="/etc/ssh/ssh_host_${key_type}_key"
    if [ ! -f "$key_file" ]; then
        if ! ssh-keygen -t "$key_type" -f "$key_file" -N ""; then
            echo "Error: Cannot generate $key_file. Check that /etc/ssh is writable, disk is not full, and the key type is supported." >&2
            exit 1
        fi
    elif [ ! -w "$key_file" ]; then
        echo "Info: $key_file exists but is not writable — using existing key (e.g., mounted from Kubernetes Secret)." >&2
    fi
done

# Start sshd in the foreground as PID 1
# exec ensures sshd receives signals directly for proper container shutdown
# -e redirects sshd logs to stderr (visible in docker logs)
exec /usr/sbin/sshd -D -e
```

## Related

- `docs/solutions/tooling-decisions/hermes-sandbox-base-image-version.md` — base image version alignment decision
- `docs/brainstorms/2026-06-21-docker-image-build-requirements.md` — requirements document with R6-R11 covering SSH configuration
