#!/usr/bin/env bash
set -euo pipefail

: "${USERNAME:?USERNAME must be set in the image environment}"

ssh-keygen -A

home="/home/${USERNAME}"

if [ ! -e "${home}/.code-pod-initialised" ]; then
    install -d -o "${USERNAME}" -g "${USERNAME}" -m 0700 "${home}/.ssh"
    chown -R "${USERNAME}:${USERNAME}" "${home}"
    touch "${home}/.code-pod-initialised"
    chown "${USERNAME}:${USERNAME}" "${home}/.code-pod-initialised"
fi

# Strip group/world write on $HOME every start. Kubernetes' fsGroup sets the
# mount root group-writable, which sshd's StrictModes rejects.
chmod g-w,o-w "${home}"

exec /usr/sbin/sshd -D -e
