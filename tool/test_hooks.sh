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
tags() { [ "$(git tag -l | sort -V | tr '\n' ' ')" = "$1 " ] || fail "$2: tags are $(git tag -l | sort -V | tr '\n' ' ')"; }
at() { [ "$(git rev-parse "$1^{commit}")" = "$(git rev-parse HEAD)" ] || fail "$2: $1 is not on HEAD"; }
app() { echo a >> lib/a.dart; git add lib; git commit -qm "${1:-App}"; }

git init -q -b main
git config user.name test
git config user.email test@example.com
git config commit.gpgsign false
git config core.hooksPath "$hooks"
printf 'name: app\nversion: 1.0.6+65\n' > pubspec.yaml
mkdir lib test
echo a > lib/a.dart
echo b > lib/b.dart
echo r > README.md
git add -A
git commit -qm init --no-verify # skips pre-commit, not post-commit
tags v1.0.6 'the first commit with a name'; at v1.0.6 'the first commit with a name'
[ "$(git cat-file -t v1.0.6)" = tag ] || fail 'v1.0.6 is not annotated, so push.followTags would leave it behind'
[ "$(git tag -l --format='%(contents:subject)' v1.0.6)" = 'Jeansh 1.0.6, build 65' ] ||
  fail "tag message: $(git tag -l --format='%(contents)' v1.0.6)"

echo r >> README.md; echo t > test/a_test.dart; echo c > CLAUDE.md
git add -A; git commit -qm 'Docs, tests and CLAUDE.md'
expect 1.0.6+65 'docs only'; untagged 'docs only'; clean 'docs only'
tags v1.0.6 'docs only'

app 'Change lib'
expect 1.0.6+66 'build bump'; tagged 66 'build bump'; clean 'build bump'
tags v1.0.6 'same name'
for n in 67 68 69 70 71 72 73 74; do app; expect "1.0.6+$n" "build $n"; done
app 'Tenth build'
expect 1.0.7+75 'patch on the tenth build past its tag'; tagged 75 'patch'; clean 'patch'
tags 'v1.0.6 v1.0.7' 'patch'; at v1.0.7 'patch'
app; expect 1.0.7+76 'build after a patch'; tags 'v1.0.6 v1.0.7' 'build after a patch'

sed 's/^version: .*/version: 1.1.0+76/' pubspec.yaml > p && mv p pubspec.yaml
git add pubspec.yaml; git commit -qm 'Version 1.1'
expect 1.1.0+76 'minor by hand'; tagged 76 'minor by hand'; clean 'minor by hand'
tags 'v1.0.6 v1.0.7 v1.1.0' 'minor by hand'; at v1.1.0 'minor by hand'

sed 's/^version: .*/version: 2.0.0+76/' pubspec.yaml > p && mv p pubspec.yaml
git add pubspec.yaml; app 'Major by hand, with the app'
expect 2.0.0+77 'major by hand with an app change'
tags 'v1.0.6 v1.0.7 v1.1.0 v2.0.0' 'major by hand'; at v2.0.0 'major by hand'

echo 'flutter: {}' >> pubspec.yaml; git add pubspec.yaml; git commit -qm 'Pubspec'
expect 2.0.0+78 'other pubspec change'; tagged 78 'other pubspec change'

mkdir windows third_party; echo w > windows/runner.cpp
git add windows; git commit -qm 'Windows'
expect 2.0.0+79 'windows/'
echo p > third_party/pty.c; git add third_party; git commit -qm 'Vendored'
expect 2.0.0+80 'third_party/'

echo a >> lib/a.dart; git add lib
git commit -q -F - <<'EOF'
Subject

Body.

Co-Authored-By: Someone <someone@example.com>
EOF
expect 2.0.0+81 trailers; tagged 81 trailers
[ "$(git log -1 --format='%(trailers:key=Co-Authored-By,valueonly)')" = 'Someone <someone@example.com>' ] ||
  fail "trailers broken: $(git log -1 --format=%B)"

echo a >> lib/a.dart; git add lib
GIT_EDITOR="sed -i.bak 1s/^/Plain/" git commit -q
expect 2.0.0+82 'plain commit'; tagged 82 'plain commit'
[ "$(git log -1 --format=%s)" = Plain ] || fail "plain commit subject: $(git log -1 --format=%s)"

echo '# note' >> pubspec.yaml; echo a >> lib/a.dart; git add lib; git commit -qm 'Unstaged edit'
expect 2.0.0+83 'unstaged edit'
if git show HEAD:pubspec.yaml | grep -q '# note'; then fail 'unstaged pubspec edit committed'; fi
[ "$(git diff -U0 | grep '^[-+][^-+]')" = '+# note' ] || fail "unstaged edit: $(git diff)"
git checkout -q pubspec.yaml

echo a >> lib/a.dart; git commit -qm 'Paths' -- lib/a.dart
expect 2.0.0+84 'git commit <paths>'; clean 'git commit <paths>'

# The patch that lands on the paths commit reaches the index as well.
for n in 85 86; do app; done
echo a >> lib/a.dart; git commit -qm 'Paths, patch' -- lib/a.dart
expect 2.0.1+87 'patch through git commit <paths>'; clean 'patch through git commit <paths>'
app; expect 2.0.1+88 'after a patch through git commit <paths>'

git checkout -q -b side
echo b >> lib/b.dart; git commit -qam 'Side'
echo b >> lib/b.dart; git commit -qam 'Side again'
git checkout -q main
app 'Main'
git checkout -q side
if git merge -q --no-edit main > /dev/null 2>&1; then fail 'expected a version conflict'; fi
git checkout -q --ours pubspec.yaml; git add pubspec.yaml; git commit -q --no-edit
expect 2.0.1+91 'conflict kept at the higher build'; untagged 'merge'; clean 'conflict merge'

# A boundary crossed without the hook, by a version-only commit, is caught up
# on the next app commit rather than waited out for ten more.
sed 's/^version: .*/version: 2.0.1+120/' pubspec.yaml > p && mv p pubspec.yaml
git add pubspec.yaml; git commit -qm 'Jump'
expect 2.0.1+120 'version only'
app; expect 2.0.2+121 'catching up a missed patch'; at v2.0.2 'catching up a missed patch'

# A branch from before semver names its builds 1.0.N+N; a merge that keeps its
# line gets the name back from the tags, and no tag for the old name.
sed 's/^version: .*/version: 2.0.125+125/' pubspec.yaml > p && mv p pubspec.yaml
git add pubspec.yaml; app 'Old shape'
expect 2.0.2+126 'an old 1.0.N+N name put right'
tags 'v1.0.6 v1.0.7 v1.1.0 v2.0.0 v2.0.1 v2.0.2' 'an old 1.0.N+N name'
sed 's/^version: .*/version: 2.0.9+126/' pubspec.yaml > p && mv p pubspec.yaml
git add pubspec.yaml; git commit -qm 'Skip ahead' 2> err
grep -q 'not tagging v2.0.9' err || fail "no warning for a patch that skips ahead: $(cat err)"; rm err
tags 'v1.0.6 v1.0.7 v1.1.0 v2.0.0 v2.0.1 v2.0.2' 'a patch that skips ahead'
app; expect 2.0.2+127 'a patch that skips ahead put right'

sed 's/^version: .*/version: 2.0+121/' pubspec.yaml > p && mv p pubspec.yaml
echo a >> lib/a.dart; git add -A
if git commit -qm 'No patch' > /dev/null 2>&1; then fail 'committed a version line that is not X.Y.Z+N'; fi

echo 'hooks: all checks passed'
