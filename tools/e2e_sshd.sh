#!/usr/bin/env bash
# e2e_sshd.sh: a throwaway user "e2e" and an sshd that takes its password on
# 127.0.0.1 only, for the e2e jobs. Exports SSH_USER and SSH_PASSWORD through
# GITHUB_ENV. Usage: tools/e2e_sshd.sh [--login-proof]
#
# sshd_config reads its Include (sshd_config.d/*.conf) first, in lexical
# order, and the FIRST value given to a keyword wins. A drop-in named 99-
# therefore loses to any earlier one: a cloud image's 50-cloud-init.conf with
# `PasswordAuthentication no` made shard 1 of run 46119695092 answer
# "Permission denied (publickey)" while its four siblings, on runners without
# that file, passed. This one is named 00- so it is read first, and what
# sshd would really use is read back with `sshd -T` before anything relies on
# it, with the drop-ins that were there printed for the log.
set -euo pipefail

password="$(openssl rand -hex 16)"
echo "::add-mask::$password"
sudo useradd -m -s /bin/bash e2e
echo "e2e:$password" | sudo chpasswd

echo "sshd_config.d before:"
sudo sh -c 'for f in /etc/ssh/sshd_config.d/*.conf; do [ -e "$f" ] && { echo "--- $f"; grep -v "^\s*#" "$f" | grep -v "^\s*$"; }; done' || true

# Loopback only: the emulator arrives there, and nothing else should.
printf 'ListenAddress 127.0.0.1\nPasswordAuthentication yes\n' |
  sudo tee /etc/ssh/sshd_config.d/00-e2e.conf >/dev/null
# Ubuntu 24.04 starts sshd from ssh.socket, which listens on every address
# whatever ListenAddress says. The service reads the config.
sudo systemctl disable --now ssh.socket 2>/dev/null || true
sudo systemctl restart ssh

# The configuration sshd will really use, not the one we meant to give it.
effective=$(sudo sshd -T 2>/dev/null)
echo "$effective" | grep -E '^(passwordauthentication|listenaddress|usepam) ' || true
echo "$effective" | grep -qx 'passwordauthentication yes' ||
  { echo "::error::sshd would refuse passwords: $(echo "$effective" | grep -i '^passwordauthentication')"; exit 1; }

# Through GITHUB_ENV, not a step output: GitHub drops any output holding a
# masked value, so the flows would get an empty password.
echo "SSH_PASSWORD=$password" >>"$GITHUB_ENV"
echo "SSH_USER=e2e" >>"$GITHUB_ENV"

# Listening: the restart returns before sshd has bound its port.
for _ in $(seq 20); do
  (exec 3<>/dev/tcp/127.0.0.1/22) 2>/dev/null && break
  sleep 1
done
(exec 3<>/dev/tcp/127.0.0.1/22) 2>/dev/null || { echo "::error::sshd did not start"; exit 1; }

if [ "${1:-}" = --login-proof ]; then
  # Prove it here, in seconds, rather than learn it from the emulator ten
  # minutes later as a seed flow that could not sign in.
  sshpass -p "$password" ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 e2e@127.0.0.1 true
  echo "sshd answers on 127.0.0.1:22 and the password works"
else
  echo "sshd answers on 127.0.0.1:22"
fi
