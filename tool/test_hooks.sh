#!/bin/sh
# Runs .githooks in a throwaway repo, and stops at the first check that fails.
#   tool/test_hooks.sh          (the repo goes under $TMPDIR, or /tmp)
set -eu
hooks=$(cd "$(dirname "$0")/../.githooks" && pwd)
t=$(mktemp -d "${TMPDIR:-/tmp}/jeansh-hooks.XXXXXX")
trap 'rm -rf "$t"' EXIT
cd "$t"

fail() { echo "FAIL: $*" >&2; exit 1; }
version() { git show HEAD:pubspec.yaml | sed -n 's/^version: //p'; }
expect() { [ "$(version)" = "$1" ] || fail "$2: HEAD has version $(version), not $1"; }
clean() { [ -z "$(git status --porcelain)" ] || fail "$1: left $(git status --porcelain)"; }
tagged() { git log -1 --format=%B | grep -qx "\[build v$1\]" || fail "$2: no [build v$1] in: $(git log -1 --format=%B)"; }
untagged() { if git log -1 --format=%B | grep -q '^\[build v'; then fail "$1: tagged"; fi; }

git init -q -b main
git config user.name test
git config user.email test@example.com
git config commit.gpgsign false
git config core.hooksPath "$hooks"
printf 'name: app\nversion: 1.0.0+13\n' > pubspec.yaml # the shape before X.Y.N+N
mkdir lib test
echo a > lib/a.dart
echo b > lib/b.dart
echo r > README.md
git add -A
git commit -qm init --no-verify

echo r >> README.md; echo t > test/a_test.dart; echo c > CLAUDE.md
git add -A; git commit -qm 'Docs, tests and CLAUDE.md'
expect 1.0.0+13 'docs only'; untagged 'docs only'; clean 'docs only'

echo a >> lib/a.dart; git add lib; git commit -qm 'Change lib'
expect 1.0.14+14 'old shape'; tagged 14 'old shape'; clean 'old shape'

sed 's/^version: 1\.0\./version: 1.1./' pubspec.yaml > p && mv p pubspec.yaml
git add pubspec.yaml; git commit -qm 'Version 1.1'
expect 1.1.14+14 'version line only'; tagged 14 'version line only'; clean 'version line only'

echo 'flutter: {}' >> pubspec.yaml; git add pubspec.yaml; git commit -qm 'Pubspec'
expect 1.1.15+15 'other pubspec change'; tagged 15 'other pubspec change'

echo a >> lib/a.dart; git add lib
git commit -q -F - <<'EOF'
Subject

Body.

Co-Authored-By: Someone <someone@example.com>
EOF
expect 1.1.16+16 trailers; tagged 16 trailers
[ "$(git log -1 --format='%(trailers:key=Co-Authored-By,valueonly)')" = 'Someone <someone@example.com>' ] ||
  fail "trailers broken: $(git log -1 --format=%B)"

echo a >> lib/a.dart; git add lib
GIT_EDITOR="sed -i.bak 1s/^/Plain/" git commit -q
expect 1.1.17+17 'plain commit'; tagged 17 'plain commit'
[ "$(git log -1 --format=%s)" = Plain ] || fail "plain commit subject: $(git log -1 --format=%s)"

echo '# note' >> pubspec.yaml; echo a >> lib/a.dart; git add lib; git commit -qm 'Unstaged edit'
expect 1.1.18+18 'unstaged edit'
if git show HEAD:pubspec.yaml | grep -q '# note'; then fail 'unstaged pubspec edit committed'; fi
[ "$(git diff -U0 | grep '^[-+][^-+]')" = '+# note' ] || fail "unstaged edit: $(git diff)"
git checkout -q pubspec.yaml

echo a >> lib/a.dart; git commit -qm 'Paths' -- lib/a.dart
expect 1.1.19+19 'git commit <paths>'; clean 'git commit <paths>'

git checkout -q -b side
echo b >> lib/b.dart; git commit -qam 'Side'
echo b >> lib/b.dart; git commit -qam 'Side again'
git checkout -q main
echo a >> lib/a.dart; git commit -qam 'Main'
git checkout -q side
if git merge -q --no-edit main > /dev/null 2>&1; then fail 'expected a version conflict'; fi
git checkout -q --ours pubspec.yaml; git add pubspec.yaml; git commit -q --no-edit
expect 1.1.22+22 'conflict kept at the higher build'; untagged 'merge'; clean 'conflict merge'

sed 's/^version: .*/version: 1.1+22/' pubspec.yaml > p && mv p pubspec.yaml
echo a >> lib/a.dart; git add -A
if git commit -qm 'No patch' > /dev/null 2>&1; then fail 'committed a version line that is not X.Y.N+N'; fi

echo 'hooks: all checks passed'
