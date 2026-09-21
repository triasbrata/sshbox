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
#     machine.
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
issue = step('tag.yml', 'issue', lambda s: 'run' in s)
open(os.path.join(work, 'issue.sh'), 'w').write(issue['run'])
close = step('tag.yml', 'promote', lambda s: 'issue' in s.get('name', ''))
open(os.path.join(work, 'close.sh'), 'w').write(close['run'])
print(nxt['env']['RELEASE_EVERY'])
PY
) || exit 1
export RELEASE_EVERY
[ "$RELEASE_EVERY" = 10 ] || { echo "these cases assume RELEASE_EVERY=10, tag.yml has $RELEASE_EVERY"; exit 1; }

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
  log=$(bash "$work/next.sh" 2>&1); code=$?
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
    bash "$work/notes.sh" 2>&1); code=$?
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
    RC=v1.0.73-rc.2 LABEL=1.0.73+74 RUN=https://run bash "$work/$2" 2>&1); code=$?
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
