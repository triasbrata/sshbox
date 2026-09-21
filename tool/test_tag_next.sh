#!/bin/bash
# Runs .github/workflows/tag.yml's `next` step for real, in a throwaway repo:
# app commits gathering to ten, a `Release: feature` trailer releasing at once,
# what does not count towards either, and the rc numbering after a failed
# candidate. Also checks that release.yml's notes count from the release
# before, never from a candidate. Needs python3 with PyYAML to read the step.
#
#   tool/test_tag_next.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

python3 - "$root/.github/workflows/tag.yml" "$work/next.sh" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))['jobs']['next']['steps']
open(sys.argv[2], 'w').write(next(s['run'] for s in steps if s.get('id') == 'next'))
PY
export RELEASE_EVERY=$(python3 -c "import sys, yaml; print(next(s['env']['RELEASE_EVERY'] for s in yaml.safe_load(open(sys.argv[1]))['jobs']['next']['steps'] if s.get('id') == 'next'))" "$root/.github/workflows/tag.yml")
[ "$RELEASE_EVERY" = 10 ] || { echo "these cases assume RELEASE_EVERY=10, tag.yml has $RELEASE_EVERY"; exit 1; }

fails=0
mkdir -p "$work/repo/lib"; cd "$work/repo"
git init -q -b main .
git config user.email ci@invalid; git config user.name CI
git config commit.gpgsign false; git config tag.gpgsign false
echo 'version: 1.0.66+67' > pubspec.yaml
git add -A; git commit -qm one
git tag -a v1.0.67 -m 'Jeansh 1.0.67, build 68'

n=0
app()  { n=$((n+1)); echo "$n" > lib/f.dart; git add -A; git commit -qm "app $n" ${1:+-m "$1"}; }
docs() { n=$((n+1)); echo "$n" > README.md;  git add -A; git commit -qm "docs $n" ${1:+-m "$1"}; }

# expect <what> <the rc tag it should make, or '' for no release>
expect() {
  export GITHUB_OUTPUT=$work/out; : > "$GITHUB_OUTPUT"
  log=$(bash "$work/next.sh" 2>&1); code=$?
  got=$(sed -n 's/^rc=//p' "$GITHUB_OUTPUT")
  if [ $code -eq 0 ] && [ "$got" = "$2" ]; then
    printf 'ok    %s\n' "$1"
  else
    printf 'FAIL  %s: want %s, got %s (exit %s)\n      %s\n' \
      "$1" "${2:-no release}" "${got:-no release}" "$code" "$log"
    fails=$((fails+1))
  fi
}

for _ in 1 2 3; do app; done
expect "3 app commits are not a release yet" ""

for _ in 1 2 3 4 5; do docs; done
expect "commits that do not change the app do not count" ""

docs 'Release: feature'
expect "a feature trailer on a commit that does not change the app is ignored" ""

git checkout -qb side; app; app; git checkout -q main
git merge -q --no-ff side -m 'Merge side'
expect "a merge commit is not counted, the commits it brings are" ""

for _ in 1 2 3 4; do app; done
expect "9 app commits are still not" ""

app
expect "the 10th app commit is a release" "v1.0.68-rc.1"

git tag -a v1.0.68-rc.1 -m 'Jeansh 1.0.68, build 69'
app
expect "after a failed rc, the next app commit tries again as rc.2" "v1.0.68-rc.2"

git tag -a v1.0.68 -m 'Jeansh 1.0.68, build 69'
app
expect "once released, the count starts again" ""

app 'Release: feature'
expect "a feature is a release at once" "v1.0.69-rc.1"

git tag -a v1.0.69 -m 'Jeansh 1.0.69, build 70'
app 'Release: bugfix'
expect "another Release value is not a feature" ""

app 'release:  Feature '
expect "the trailer is read regardless of case and spacing" "v1.0.70-rc.1"

# release.yml's notes, for v1.0.70 with a failed candidate just before it.
git tag -a v1.0.70-rc.1 -m 'Jeansh 1.0.70, build 71' HEAD~1
app; git tag -a v1.0.70 -m 'Jeansh 1.0.70, build 71'
prev=$(git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude '*-rc.*' 'v1.0.70^')
if [ "$prev" = v1.0.69 ]; then
  echo "ok    release notes count from the release before, not a candidate"
else
  echo "FAIL  release notes count from $prev, want v1.0.69"; fails=$((fails+1))
fi

[ $fails -eq 0 ] && echo "all passed" || echo "$fails failed"
exit $fails
