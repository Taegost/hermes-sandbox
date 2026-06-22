# Hermes Sandbox

A minimal, secure SSH backend sandbox for [Hermes Agent](https://hermes-agent.nousresearch.com/) — provides Python 3.13 and Node.js 22 runtimes with passwordless SSH access on port 2222.

## Quick Start

### Build

```bash
docker build -t hermes-sandbox .
```

### Run

Mount your SSH authorized_keys file at runtime:

```bash
docker run -d \
  -p 2222:2222 \
  -v /path/to/authorized_keys:/home/hermes/.ssh/authorized_keys:ro \
  hermes-sandbox
```

### Connect

```bash
ssh -p 2222 hermes@localhost
```

## Included Packages

| Package | Purpose |
|---------|---------|
| `bash` | Default shell for Hermes Agent's persistent session |
| `ripgrep` | Fast file search used by agent skills |
| `git` | Version control for code manipulation tasks |
| `ffmpeg` | Media processing capabilities |
| `xz-utils` | Archive compression/decompression |
| `openssh-server` | SSH server for agent connections |
| `openssh-client` | SSH client for rsync and remote operations |
| `rsync` | File synchronization between agent and sandbox |

## Kubernetes Deployment

### Secret for SSH Keys

Create a Secret containing your authorized_keys:

```bash
kubectl create secret generic hermes-ssh-keys \
  --from-file=authorized_keys=~/.ssh/authorized_keys
```

### Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hermes-sandbox
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hermes-sandbox
  template:
    metadata:
      labels:
        app: hermes-sandbox
    spec:
      containers:
        - name: sandbox
          image: hermes-sandbox:latest
          ports:
            - containerPort: 2222
          volumeMounts:
            - name: ssh-keys
              mountPath: /home/hermes/.ssh/authorized_keys
              subPath: authorized_keys
              readOnly: true
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
      volumes:
        - name: ssh-keys
          secret:
            secretName: hermes-ssh-keys
            defaultMode: 0600
```

### Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: hermes-sandbox
spec:
  selector:
    app: hermes-sandbox
  ports:
    - port: 22
      targetPort: 2222
      protocol: TCP
```

The Service maps external port 22 to container port 2222, so agents connect on the standard SSH port.

## Configuration

### SSH

- **Port:** 2222 (non-standard port to avoid conflicts with host sshd)
- **Authentication:** Key-based only, no passwords
- **Authorized keys:** Mounted at `/home/hermes/.ssh/authorized_keys`
- **ControlMaster:** Client-side feature — configure in your `~/.ssh/config` (not in sshd_config). The server supports multiplexed connections transparently.
- **Host keys:** Generated at startup by entrypoint.sh. Mount custom host keys at `/etc/ssh/` to override and maintain consistency across restarts.

### User

- **Username:** `hermes`
- **UID:GID:** `10000:10000`
- **Home:** `/home/hermes`
- **Shell:** `/bin/bash`

## Security Notes

- sshd runs as root (required for privilege separation and port binding); SSH sessions run as non-root user `hermes` (UID 10000)
- No passwords stored or accepted — key-based authentication only
- Root login is explicitly disabled (`PermitRootLogin no`)
- SSH access restricted to `hermes` user only (`AllowUsers hermes`)
- `allowPrivilegeEscalation: true` is required — sshd calls `setuid()` to drop from root to the authenticated user; `no_new_privs` blocks this and every SSH session fails
- `capabilities: drop: ["ALL"]` is incompatible — sshd needs `SETUID`, `SETGID`, and `SYS_CHROOT` for privilege separation. Use the minimal `securityContext` shown in the Deployment example
- Clusters enforcing `RuntimeDefault` seccomp may block sshd's `chroot(2)` syscall even with `SYS_CHROOT` capability. If sshd fails to accept connections, set `seccompProfile.type: Unconfined` in the container's `securityContext`
- SSH authorized_keys mounted read-only at runtime (not baked into image)
- No Playwright, Chromium, or docker-cli installed

## Base Image

Built on [nikolaik/python-nodejs:python3.13-nodejs22](https://hub.docker.com/r/nikolaik/python-nodejs) — Debian Trixie with Python 3.13 and Node.js 22 pre-installed.
