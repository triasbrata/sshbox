#!/bin/sh
# Runs .githooks in a throwaway repo, and stops at the first check that fails.
#   tool/test_hooks.sh          (the repo goes under $TMPDIR, or /tmp)
set -eu
hooks=$(cd "$(dirname "$0")/../.githooks" && pwd)
t=$(mktemp -d "${TMPDIR:-/tmp}/jeansh-hooks.XXXXXX")
trap 'rm -rf "$t"' EXIT
cd "$t"

fail() { echo "FAIL: $*" >&2; exit 1; }
build() { git show HEAD:pubspec.yaml | sed -n 's/^version:.*+//p'; }
expect() { [ "$(build)" = "$1" ] || fail "$2: HEAD has build $(build), not $1"; }
clean() { [ -z "$(git status --porcelain)" ] || fail "$1: left $(git status --porcelain)"; }
tagged() { git log -1 --format=%B | grep -qx "\[build v$1\]" || fail "$2: no [build v$1] in: $(git log -1 --format=%B)"; }
untagged() { if git log -1 --format=%B | grep -q '^\[build v'; then fail "$1: tagged"; fi; }

git init -q -b main
git config user.name test
git config user.email test@example.com
git config commit.gpgsign false
git config core.hooksPath "$hooks"
printf 'name: app\nversion: 1.0.0+1\n' > pubspec.yaml
mkdir lib test
echo a > lib/a.dart
echo b > lib/b.dart
echo r > README.md
git add -A
git commit -qm init --no-verify

echo a >> lib/a.dart; git add lib; git commit -qm 'Change lib'
expect 2 'lib change'; tagged 2 'lib change'; clean 'lib change'

echo r >> README.md; echo t > test/a_test.dart; echo c > CLAUDE.md
git add -A; git commit -qm 'Docs, tests and CLAUDE.md'
expect 2 'docs only'; untagged 'docs only'; clean 'docs only'

sed 's/^version: 1.0.0/version: 1.1.0/' pubspec.yaml > p && mv p pubspec.yaml
git add pubspec.yaml; git commit -qm 'Version 1.1.0'
expect 2 'version line only'; tagged 2 'version line only'; clean 'version line only'
git show HEAD:pubspec.yaml | grep -qx 'version: 1.1.0+2' || fail 'version name lost'

echo 'flutter: {}' >> pubspec.yaml; git add pubspec.yaml; git commit -qm 'Pubspec'
expect 3 'other pubspec change'; tagged 3 'other pubspec change'

echo a >> lib/a.dart; git add lib
git commit -q -F - <<'EOF'
Subject

Body.

Co-Authored-By: Someone <someone@example.com>
EOF
expect 4 trailers; tagged 4 trailers
[ "$(git log -1 --format='%(trailers:key=Co-Authored-By,valueonly)')" = 'Someone <someone@example.com>' ] ||
  fail "trailers broken: $(git log -1 --format=%B)"

echo a >> lib/a.dart; git add lib
GIT_EDITOR="sed -i.bak 1s/^/Plain/" git commit -q
expect 5 'plain commit'; tagged 5 'plain commit'
[ "$(git log -1 --format=%s)" = Plain ] || fail "plain commit subject: $(git log -1 --format=%s)"

echo '# note' >> pubspec.yaml; echo a >> lib/a.dart; git add lib; git commit -qm 'Unstaged edit'
expect 6 'unstaged edit'
if git show HEAD:pubspec.yaml | grep -q '# note'; then fail 'unstaged pubspec edit committed'; fi
[ "$(git diff -U0 | grep '^[-+][^-+]')" = '+# note' ] || fail "unstaged edit: $(git diff)"
git checkout -q pubspec.yaml

echo a >> lib/a.dart; git commit -qm 'Paths' -- lib/a.dart
expect 7 'git commit <paths>'; clean 'git commit <paths>'

git checkout -q -b side
echo b >> lib/b.dart; git commit -qam 'Side'
echo b >> lib/b.dart; git commit -qam 'Side again'
git checkout -q main
echo a >> lib/a.dart; git commit -qam 'Main'
git checkout -q side
if git merge -q --no-edit main > /dev/null 2>&1; then fail 'expected a version conflict'; fi
git checkout -q --ours pubspec.yaml; git add pubspec.yaml; git commit -q --no-edit
expect 10 'conflict kept at the higher build'; untagged 'merge'; clean 'conflict merge'

echo 'hooks: all checks passed'
