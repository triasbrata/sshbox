#!/usr/bin/env bash
# Fails when anything in a Linux release tarball needs a glibc newer than
# the oldest one Jeansh supports, 2.35 (Ubuntu 22.04, and Debian 12's 2.36):
# a build on a newer runner links the newer symbols and will not start there.
#
#   tools/check_glibc.sh dist/<label>/Jeansh-<label>-linux-x64.tar.gz [max]
set -euo pipefail

tarball=$1
max=${2:-2.35}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -C "$work" -xzf "$tarball"

# Whether version $1 is newer than $2.
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

worst=0
failed=0
while IFS= read -r -d '' file; do
  case $(file -b "$file") in ELF*) ;; *) continue ;; esac
  need=$(objdump -T "$file" | { grep -o 'GLIBC_[0-9.]*' || true; } |
    sed 's/GLIBC_//' | sort -uV | tail -1)
  [ -n "$need" ] || continue
  echo "${file#"$work"/}: GLIBC_$need"
  if newer "$need" "$worst"; then worst=$need; fi
  if newer "$need" "$max"; then
    echo "::error::${file#"$work"/} needs GLIBC_$need, newer than $max"
    failed=1
  fi
done < <(find "$work" -type f -print0 | sort -z)

echo "Newest glibc needed: $worst (at most $max allowed)"
exit $failed
