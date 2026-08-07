#!/usr/bin/env bash
set -euo pipefail

: "${USERNAME:?USERNAME must be set in the image environment}"

# Persistent host keys live on a dedicated PVC mounted here. Generate any
# missing keys; sshd is told to use them via a generated sshd_config drop-in.
hostkeys_dir="/var/lib/code-pod/ssh-host-keys"
mkdir -p "${hostkeys_dir}"
chown root:root "${hostkeys_dir}"
chmod 0700 "${hostkeys_dir}"
for keytype in ed25519 rsa ecdsa; do
    keyfile="${hostkeys_dir}/ssh_host_${keytype}_key"
    if [ ! -s "${keyfile}" ]; then
        ssh-keygen -q -N "" -t "${keytype}" -f "${keyfile}"
    fi
done
chown root:root "${hostkeys_dir}"/ssh_host_*
chmod 0600 "${hostkeys_dir}"/ssh_host_*_key
chmod 0644 "${hostkeys_dir}"/ssh_host_*_key.pub
cat > /etc/ssh/sshd_config.d/00-hostkeys.conf <<EOF
HostKey ${hostkeys_dir}/ssh_host_ed25519_key
HostKey ${hostkeys_dir}/ssh_host_rsa_key
HostKey ${hostkeys_dir}/ssh_host_ecdsa_key
EOF

home="/home/${USERNAME}"

if [ ! -e "${home}/.code-pod-initialised" ]; then
    install -d -o "${USERNAME}" -g "${USERNAME}" -m 0700 "${home}/.ssh"
    chown -R "${USERNAME}:${USERNAME}" "${home}"
    touch "${home}/.code-pod-initialised"
    chown "${USERNAME}:${USERNAME}" "${home}/.code-pod-initialised"
fi

# Strip group/world write on $HOME and ~/.ssh every start. Kubernetes' fsGroup
# sets mount roots group-writable (recursing through .ssh too), which ssh/git
# refuse to use as private keys ("UNPROTECTED PRIVATE KEY FILE"). Only a
# one-shot fix (it doesn't survive a later kubelet/CSI reconcile that re-widens
# the mount without restarting this container) but it's cheap insurance, and
# it's why authorized_keys is served from the read-only ssh-seed Secret mount
# instead of a copy here: sshd never sees this volume's permissions for login.
# Re-tighten on every start, not just first init.
chmod g-w,o-w "${home}"
if [ -d "${home}/.ssh" ]; then
    chmod 0700 "${home}/.ssh"
    find "${home}/.ssh" -maxdepth 1 -type f \
        ! -name '*.pub' ! -name known_hosts ! -name config \
        -exec chmod 0600 {} +
    find "${home}/.ssh" -maxdepth 1 -type f \
        \( -name '*.pub' -o -name known_hosts -o -name config \) \
        -exec chmod 0644 {} +
fi

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

# Same PVC-shadow issue for oh-my-tmux. Runs as root, unlike the omf block
# above: $HOME's group-write is stripped for sshd's StrictModes (see above),
# so the unprivileged user can't create new top-level entries like .tmux/ or
# .tmux.conf; chown the results afterward instead.
if [ ! -d "${home}/.tmux" ]; then
    (
        set -e
        git clone --depth=1 https://github.com/gpakosz/.tmux.git "${home}/.tmux"
        ln -s -f .tmux/.tmux.conf "${home}/.tmux.conf"
        [ -f "${home}/.tmux.conf.local" ] || cp "${home}/.tmux/.tmux.conf.local" "${home}/.tmux.conf.local"
        chown -R "${USERNAME}:${USERNAME}" "${home}/.tmux" "${home}/.tmux.conf" "${home}/.tmux.conf.local"
    ) || echo "warn: oh-my-tmux install failed; continuing"
fi

exec /usr/sbin/sshd -D -e
