#!/bin/bash
# Runs the release flow's own steps for real, in throwaway repos:
#
#   - every call of one workflow from another: what GitHub checks before a run
#     starts, which the steps' own shell never sees;
#   - tag.yml's `next`: app commits gathering to ten, a `Release: feature`
#     trailer releasing at once, what counts towards neither, and the rc
#     numbering after a failed candidate;
#   - release.yml's notes: which commits a release's notes cover, against a
#     stand-in for R2 and for tool/release_notes.py, so nothing leaves this
#     machine;
#   - release.yml's feed: latest.json from R2 as the builds leave it, Windows'
#     binary-mode SHA256SUMS included;
#   - tag.yml's issue for a failed candidate, and promote closing it, against
#     a stand-in for gh.
#
# Needs python3 with PyYAML, to read the steps out of the workflows, and jq.
#
#   tool/test_release_flow.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

RELEASE_EVERY=$(python3 - "$root/.github/workflows" "$work" <<'PY'
import os, sys, yaml
flows, work = sys.argv[1:]
def step(path, job, match):
    steps = yaml.safe_load(open(os.path.join(flows, path)))['jobs'][job]['steps']
    return next(s for s in steps if match(s))
nxt = step('tag.yml', 'next', lambda s: s.get('id') == 'next')
open(os.path.join(work, 'next.sh'), 'w').write(nxt['run'])
notes = step('release.yml', 'notes', lambda s: 'release notes' in s.get('name', ''))
open(os.path.join(work, 'notes.sh'), 'w').write(notes['run'])
feed = step('release.yml', 'feed', lambda s: 'latest.json' in s.get('name', ''))
open(os.path.join(work, 'feed.sh'), 'w').write(feed['run'])
issue = step('tag.yml', 'issue', lambda s: 'run' in s)
open(os.path.join(work, 'issue.sh'), 'w').write(issue['run'])
close = step('tag.yml', 'promote', lambda s: 'issue' in s.get('name', ''))
open(os.path.join(work, 'close.sh'), 'w').write(close['run'])
print(nxt['env']['RELEASE_EVERY'])
PY
) || exit 1
export RELEASE_EVERY
[ "$RELEASE_EVERY" = 10 ] || { echo "these cases assume RELEASE_EVERY=10, tag.yml has $RELEASE_EVERY"; exit 1; }

# Every step runs the way GitHub runs a bash `run:`, and not otherwise: -e
# and pipefail are what turn a failed lookup into a failed job, and a step
# run without them can pass here and fail there.
step_shell="bash --noprofile --norc -eo pipefail"

fails=0
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n      %s\n' "$1" "$2"; fails=$((fails+1)); }

## Every call of one workflow from another ##################################

# What GitHub checks before it starts a run, and refuses the whole run over
# with no job ever created: a called workflow's jobs may ask for no more than
# the job calling it grants, and a call may pass no input the called workflow
# does not declare, nor leave out one it requires. actionlint checks none of
# this; tag.yml once failed every run on the first of them.
calls=$(python3 - "$root/.github/workflows" <<'PY'
import os, sys, yaml
flows = sys.argv[1]
LEVEL = {'none': 0, 'read': 1, 'write': 2}
# With no permissions anywhere, this repository's token reads, and no more.
DEFAULT = {'contents': 'read'}

def perms(p, fallback):
    if p is None:
        return fallback
    if isinstance(p, str):  # read-all, write-all
        return {'*': p.split('-')[0]}
    return p

def level(grant, scope):
    return LEVEL[grant.get(scope, grant.get('*', 'none'))]

def load(name):
    doc = yaml.safe_load(open(os.path.join(flows, name)))
    return doc, doc.get('on', doc.get(True)) or {}   # YAML 1.1 reads on: as True

bad = []
for name in sorted(f for f in os.listdir(flows) if f.endswith(('.yml', '.yaml'))):
    doc, _ = load(name)
    for job_id, job in doc.get('jobs', {}).items():
        uses = job.get('uses', '')
        if not uses.startswith('./.github/workflows/'):
            continue
        callee = os.path.basename(uses)
        where = f'{name} job {job_id} calling {callee}'
        grant = perms(job.get('permissions'), perms(doc.get('permissions'), DEFAULT))
        cdoc, con = load(callee)
        call = (con.get('workflow_call') or {}) if isinstance(con, dict) else {}
        for k_id, k in cdoc.get('jobs', {}).items():
            want = perms(k.get('permissions'), perms(cdoc.get('permissions'), grant))
            for scope, lvl in want.items():
                if LEVEL[lvl] > level(grant, scope):
                    bad.append(f"{where}: its job {k_id} asks for {scope}: {lvl}, "
                               f"but {job_id} grants {scope}: {grant.get(scope, grant.get('*', 'none'))}")
        declared = call.get('inputs') or {}
        given = job.get('with') or {}
        for key in given:
            if key not in declared:
                bad.append(f'{where}: passes input {key}, which {callee} does not declare')
        for key, spec in declared.items():
            if (spec or {}).get('required') and key not in given:
                bad.append(f'{where}: leaves out {key}, which {callee} requires')
        secrets = job.get('secrets')
        if isinstance(secrets, dict):
            for key in secrets:
                if key not in (call.get('secrets') or {}):
                    bad.append(f'{where}: passes secret {key}, which {callee} does not declare')
        print(f'checked {where}')
for line in bad:
    print('BAD ' + line)
PY
) || { echo "could not read the workflows"; exit 1; }
if grep -q '^BAD ' <<< "$calls"; then
  fail "every call of one workflow from another would start" "$(sed -n 's/^BAD //p' <<< "$calls")"
elif grep -q '^checked ' <<< "$calls"; then
  pass "every call of one workflow from another would start ($(grep -c '^checked ' <<< "$calls") checked)"
else
  fail "every call of one workflow from another would start" "no calls found to check"
fi

repo() {
  rm -rf "$work/repo"; mkdir -p "$work/repo/lib"; cd "$work/repo"
  git init -q -b main .
  git config user.email ci@invalid; git config user.name CI
  git config commit.gpgsign false; git config tag.gpgsign false
  echo 'version: 1.0.66+67' > pubspec.yaml
  git add -A; git commit -qm one
  git tag -a v1.0.67 -m 'Jeansh 1.0.67, build 68'
  n=0
}
app()  { n=$((n+1)); echo "$n" > lib/f.dart; git add -A; git commit -qm "${2:-app $n}" ${1:+-m "$1"}; }
docs() { n=$((n+1)); echo "$n" > README.md;  git add -A; git commit -qm "docs $n" ${1:+-m "$1"}; }

## tag.yml's next ###########################################################

# expect <what> <the rc tag it should make, or '' for no release>
expect() {
  export GITHUB_OUTPUT=$work/out; : > "$GITHUB_OUTPUT"
  log=$($step_shell "$work/next.sh" 2>&1); code=$?
  got=$(sed -n 's/^rc=//p' "$GITHUB_OUTPUT")
  if [ $code -eq 0 ] && [ "$got" = "$2" ]; then pass "$1"
  else fail "$1" "want ${2:-no release}, got ${got:-no release} (exit $code): $log"; fi
}

repo
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

## release.yml's notes ######################################################

# R2, as far as the notes step uses it: site/releases.json, read and written.
mkdir -p "$work/bin"
cat > "$work/bin/aws" <<'SH'
#!/bin/bash
list=$R2_LIST
case " $* " in
  *" head-object "*) [ -f "$list" ] || { echo 'An error occurred (404) when calling the HeadObject operation: Not Found' >&2; exit 254; } ;;
  *" s3 cp "*)
    src=${@: -2:1}; dest=${@: -1}
    if [ "${src#s3://}" != "$src" ]; then cp "$list" "$dest"; else cp "$src" "$list"; fi ;;
  *) echo "stub aws: unexpected $*" >&2; exit 1 ;;
esac
SH
chmod +x "$work/bin/aws"

# notes <what> <tag> <list as JSON, or '' for none> <subjects wanted> <subjects not wanted>
notes() {
  export R2_LIST=$work/releases.json RUNNER_TEMP=$work/run
  rm -rf "$RUNNER_TEMP" "$R2_LIST"; mkdir -p "$RUNNER_TEMP"
  [ -z "$3" ] || printf '%s' "$3" > "$R2_LIST"
  # The model stands in as a copy of what it would have been handed.
  mkdir -p tool
  printf '%s\n' 'import shutil, sys' \
    'shutil.copy(sys.argv[sys.argv.index("--changes") + 1], sys.argv[-1] + ".changes")' > tool/release_notes.py
  local name=${2#v}
  log=$(PATH=$work/bin:$PATH TAG=$2 NAME=$name BUILD=1 \
    OPENROUTER_API_KEY=x AWS_ACCESS_KEY_ID=x AWS_SECRET_ACCESS_KEY=x R2_ENDPOINT=x R2_BUCKET=b \
    $step_shell "$work/notes.sh" 2>&1); code=$?
  rm -rf tool
  got=$(cat "$RUNNER_TEMP/releases.json.changes" 2>/dev/null)
  local bad=""
  for s in $4; do grep -qx "\* $s" <<< "$got" || bad="$bad missing $s;"; done
  for s in $5; do grep -qx "\* $s" <<< "$got" && bad="$bad has $s;"; done
  if [ $code -eq 0 ] && [ -z "$bad" ]; then pass "$1"
  else fail "$1" "exit $code;$bad $(tail -n 1 <<< "$log")"; fi
}

repo
app '' a1; git tag -a v1.0.68 -m 'Jeansh 1.0.68, build 69'
app '' b1; git tag -a v1.0.69-rc.1 -m 'Jeansh 1.0.69, build 70'
app '' b2; git tag -a v1.0.69 -m 'Jeansh 1.0.69, build 70'
app '' c1; git tag -a v1.0.70 -m 'Jeansh 1.0.70, build 71'
docs; app '' d1; git tag -a v1.0.71 -m 'Jeansh 1.0.71, build 72'

notes "the notes cover the commits since the last release with notes" \
  v1.0.69 '[{"version":"1.0.68"},{"version":"1.0.67"}]' "b1 b2" "a1 c1"

notes "a failed candidate before the release does not cut them short" \
  v1.0.69 '[]' "b1 b2" "a1"

notes "a release whose build went red has its changes in the next one's notes" \
  v1.0.70 '[{"version":"1.0.68"},{"version":"1.0.67"}]' "b1 b2 c1" "a1"

notes "notes written again for the same release cover the same commits" \
  v1.0.70 '[{"version":"1.0.70"},{"version":"1.0.68"}]' "b1 b2 c1" "a1"

notes "a tag released again by hand counts from the release before it" \
  v1.0.69 '[{"version":"1.0.71"},{"version":"1.0.70"}]' "b1 b2" "a1 c1 d1"

notes "with no list yet, from the release before" \
  v1.0.71 '' "d1" "c1"

notes "a listed version with no tag falls back to the release before" \
  v1.0.71 '[{"version":"9.9.9"}]' "d1" "c1"

## release.yml's feed #######################################################

# R2's desktop/, as the feed step reads it: each target's SHA256SUMS, and an
# object's size by its key. Anything not in $FIXTURES is a 404, as R2 says it.
mkdir -p "$work/feedbin"
cat > "$work/feedbin/aws" <<'SH'
#!/bin/bash
args=("$@")
case " $* " in
  *" s3 cp "*) src=${args[-2]}; cp "$FIXTURES/${src#*/desktop/}" "${args[-1]}" ;;
  *" head-object "*)
    for i in "${!args[@]}"; do [ "${args[$i]}" = --key ] && key=${args[$((i+1))]}; done
    [ -f "$FIXTURES/${key#desktop/}" ] || { echo 'An error occurred (404) when calling the HeadObject operation: Not Found' >&2; exit 254; }
    stat -c %s "$FIXTURES/${key#desktop/}" ;;
  *) echo "stub aws: unexpected $*" >&2; exit 1 ;;
esac
SH
chmod +x "$work/feedbin/aws"

# One release in R2 as the release builds leave it: Linux and macOS write
# SHA256SUMS in text mode, and Windows' Git Bash in binary mode, "<hash> *<name>".
builds() {
  export FIXTURES=$work/r2
  rm -rf "$FIXTURES"; mkdir -p "$FIXTURES"/{linux,windows,macos}
  printf 'linux'   > "$FIXTURES/linux/Jeansh-$1-linux-x64.tar.gz"
  printf 'windows!' > "$FIXTURES/windows/Jeansh-$1-windows-x64.zip"
  printf 'mac zip'  > "$FIXTURES/macos/Jeansh-$1-macos.zip"
  printf 'mac dmg!!' > "$FIXTURES/macos/Jeansh-$1-macos.dmg"
  (cd "$FIXTURES/linux"   && sha256sum --text   -- * > SHA256SUMS)
  (cd "$FIXTURES/windows" && sha256sum --binary -- * > SHA256SUMS)
  (cd "$FIXTURES/macos"   && sha256sum --text   -- * > SHA256SUMS)
}

# feed <label> -> runs the step for that release; $feed_out is latest.json
feed() {
  export RUNNER_TEMP=$work/feedrun; rm -rf "$RUNNER_TEMP"; mkdir -p "$RUNNER_TEMP"
  feed_log=$(PATH=$work/feedbin:$PATH NAME=${1%+*} BUILD=${1#*+} LABEL=$1 \
    AWS_ACCESS_KEY_ID=x AWS_SECRET_ACCESS_KEY=x R2_ENDPOINT=x R2_BUCKET=b \
    $step_shell "$work/feed.sh" 2>&1); feed_code=$?
  feed_out=$(cat "$RUNNER_TEMP/latest.json" 2>/dev/null)
}

builds 1.0.73+77
feed 1.0.73+77
want() { # want <target> <file>
  local f=$FIXTURES/$1/$2
  jq -e --arg t "$1" --arg p "desktop/$1/$2" --arg s "$(sha256sum < "$f" | cut -c1-64)" \
    --argjson z "$(stat -c %s "$f")" \
    '.platforms[$t] == {path: $p, size: $z, sha256: $s}' <<< "$feed_out" > /dev/null
}
if [ $feed_code -eq 0 ] && want linux Jeansh-1.0.73+77-linux-x64.tar.gz &&
   want windows Jeansh-1.0.73+77-windows-x64.zip && want macos Jeansh-1.0.73+77-macos.zip &&
   jq -e '.version == "1.0.73" and .build == 77' <<< "$feed_out" > /dev/null; then
  pass "the feed reads every build, Windows' binary-mode SHA256SUMS too"
else
  fail "the feed reads every build, Windows' binary-mode SHA256SUMS too" "exit $feed_code: $(tail -n 2 <<< "$feed_log") $feed_out"
fi

builds 1.0.72+76
feed 1.0.73+77
if [ $feed_code -ne 0 ] && grep -q "not this release's 1.0.73+77" <<< "$feed_log"; then
  pass "a feed whose builds in R2 are not this release's is refused"
else
  fail "a feed whose builds in R2 are not this release's is refused" "exit $feed_code: $(tail -n 1 <<< "$feed_log")"
fi

builds 1.0.73+77
rm "$FIXTURES/windows/Jeansh-1.0.73+77-windows-x64.zip"
feed 1.0.73+77
if [ $feed_code -ne 0 ] && grep -q "names Jeansh-1.0.73+77-windows-x64.zip for windows, and R2 has no such object" <<< "$feed_log"; then
  pass "a build SHA256SUMS names but R2 does not hold is named in the error"
else
  fail "a build SHA256SUMS names but R2 does not hold is named in the error" "exit $feed_code: $(tail -n 1 <<< "$feed_log")"
fi

## tag.yml's issue, and promote closing it ##################################

# gh, as far as those steps use it: `issue list` answers with $GH_ISSUES, and
# everything else is written down rather than done.
cat > "$work/bin/gh" <<'SH'
#!/bin/bash
case "$1 $2" in
  "issue list") printf '%s' "$GH_ISSUES" ;;
  "issue create"|"issue comment"|"issue close")
    out="$1 $2"; shift 2
    while [ $# -gt 0 ]; do
      case $1 in --repo) shift 2 ;; --title) out="$out title=[$2]"; shift 2 ;;
        --body|--comment) shift 2 ;; *) out="$out $1"; shift ;; esac
    done
    echo "$out" >> "$GH_LOG" ;;
  *) echo "stub gh: unexpected $*" >&2; exit 1 ;;
esac
SH
chmod +x "$work/bin/gh"

# gh_step <what> <script> <open issues as JSON> <the one call it should make, or ''>
gh_step() {
  export GH_LOG=$work/gh.log GH_ISSUES=$3; : > "$GH_LOG"
  log=$(PATH=$work/bin:$PATH GH_TOKEN=x GITHUB_REPOSITORY=o/r GITHUB_SHA=abc TAG=v1.0.73 \
    RC=v1.0.73-rc.2 LABEL=1.0.73+74 RUN=https://run $step_shell "$work/$2" 2>&1); code=$?
  got=$(cat "$GH_LOG")
  if [ $code -eq 0 ] && [ "$got" = "$4" ]; then pass "$1"
  else fail "$1" "want [${4}], got [${got}] (exit $code): $(tail -n 1 <<< "$log")"; fi
}

title='v1.0.73 did not pass its end-to-end tests'
gh_step "a failed candidate with no issue for its release opens one" \
  issue.sh '[]' "issue create title=[$title]"
gh_step "a later failed candidate of the same release adds to its issue" \
  issue.sh "[{\"number\":5,\"title\":\"$title\"}]" "issue comment 5"
gh_step "another release's issue is not the one" \
  issue.sh '[{"number":4,"title":"v1.0.72 did not pass its end-to-end tests"}]' "issue create title=[$title]"
gh_step "promoting closes the release's issue" \
  close.sh "[{\"number\":4,\"title\":\"v1.0.72 did not pass its end-to-end tests\"},{\"number\":5,\"title\":\"$title\"}]" "issue close 5"
gh_step "promoting with no issue closes nothing" \
  close.sh '[]' ""

[ $fails -eq 0 ] && echo "all passed" || echo "$fails failed"
exit $fails
