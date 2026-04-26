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
