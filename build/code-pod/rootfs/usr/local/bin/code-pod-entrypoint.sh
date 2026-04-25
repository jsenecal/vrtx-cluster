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

# Bootstrap Oh My Fish into $HOME if missing. The image build does this too,
# but the home PVC mount shadows that install — so we redo it on first PVC use.
if [ ! -d "${home}/.local/share/omf" ]; then
    runuser -u "${USERNAME}" -- bash -c '
        set -e
        curl -fsSL https://raw.githubusercontent.com/oh-my-fish/oh-my-fish/master/bin/install -o /tmp/omf-install
        fish /tmp/omf-install --noninteractive --yes
        rm -f /tmp/omf-install
    ' || echo "warn: omf install failed; continuing"
fi

exec /usr/sbin/sshd -D -e
