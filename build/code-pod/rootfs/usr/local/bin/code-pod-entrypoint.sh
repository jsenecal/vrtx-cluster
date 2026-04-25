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

exec /usr/sbin/sshd -D -e
