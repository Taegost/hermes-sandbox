FROM nikolaik/python-nodejs:python3.13-nodejs22

# Install system packages required by Hermes Agent's shell-based workflow
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash \
        ripgrep \
        git \
        ffmpeg \
        xz-utils \
        openssh-server \
        openssh-client \
        rsync && \
    rm -f /etc/ssh/ssh_host_* && \
    rm -rf /var/lib/apt/lists/*

# Remove base image user 'pn' to avoid confusion
RUN if getent passwd pn > /dev/null 2>&1; then userdel -r pn || true; fi

# Create hermes user with specific UID:GID
RUN groupadd -g 10000 hermes && \
    useradd -m -u 10000 -g 10000 -s /bin/bash hermes

# Create SSH directory with correct permissions
RUN mkdir -p /home/hermes/.ssh && \
    chmod 700 /home/hermes/.ssh && \
    chown hermes:hermes /home/hermes/.ssh

# Create sshd privilege separation directory
RUN mkdir -p /var/run/sshd

# Copy SSH configuration
COPY sshd_config /etc/ssh/sshd_config

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 2222

# sshd runs as root (it drops privileges to the authenticated user).
# Security is enforced by sshd_config: key-only auth, no passwords.
ENTRYPOINT ["/entrypoint.sh"]
