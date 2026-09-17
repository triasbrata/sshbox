#!/bin/sh
# Checks what tool/play_publish.py refuses, and that it never prints the key:
#   tool/test_play_publish.sh
# It needs no service account and reaches no network -- every case here is
# refused before the first API call, which is the point of them.
set -eu
cd "$(dirname "$0")/.."
t=$(mktemp -d "${TMPDIR:-/tmp}/jeansh-play.XXXXXX")
trap 'rm -rf "$t"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

secret=SHHH-NOT-A-REAL-KEY
cat > "$t/key.json" <<EOF
{"type": "service_account", "client_email": "bot@example.iam.gserviceaccount.com",
 "private_key": "-----BEGIN PRIVATE KEY-----\n$secret\n-----END PRIVATE KEY-----\n",
 "token_uri": "https://oauth2.googleapis.com/token"}
EOF
echo 'not json' > "$t/broken.json"
printf '{"type": "service_account", "client_email": "bot@example.com"}\n' > "$t/nokey.json"
: > "$t/empty.aab"

key=$t/key.json
run() { # <key path> <args...>: the script's output, however it ends
  k=$1; shift
  PLAY_SERVICE_ACCOUNT_JSON=$k python3 tool/play_publish.py "$@" 2>&1 || true
}
refuses() { # <what> <key path> <expected in the message> <args...>
  what=$1 k=$2 want=$3; shift 3
  if PLAY_SERVICE_ACCOUNT_JSON=$k python3 tool/play_publish.py "$@" >"$t/out" 2>&1; then
    fail "$what: it did not refuse ($(cat "$t/out"))"
  fi
  grep -q -- "$want" "$t/out" || fail "$what: no \"$want\" in: $(cat "$t/out")"
  grep -q -- "$secret" "$t/out" && fail "$what: it printed the private key"
  true
}

refuses "a missing key"   "$t/none.json" PLAY_SERVICE_ACCOUNT_JSON --preflight
refuses "a key that is not JSON" "$t/broken.json" "is not JSON" --preflight
refuses "a key with no private_key" "$t/nokey.json" private_key --preflight
refuses "a track that is not an id" "$key" "is not a track id" --preflight --track "bad track"
refuses "an empty track"  "$key" "is not a track id" --preflight --track ""
refuses "production"      "$key" "testing tracks only" --preflight --track production
refuses "a missing bundle" "$key" "no bundle at" "$t/nothere.aab"
refuses "an empty bundle" "$key" "is empty" "$t/empty.aab"
refuses "no bundle at all" "$key" "which bundle" --track alpha

out=$(run "$key" --preflight)
case $out in *"on alpha"*) ;; *) fail "a good setup: $out" ;; esac
out=$(run "$key" --preflight --track jeansh-testers)
case $out in *"on jeansh-testers"*) ;; *) fail "a custom track: $out" ;; esac
case $(run "$key" --help) in *--dry-run*) ;; *) fail "--help says nothing about --dry-run" ;; esac

# The sign-in token is the one part no refusal reaches, so it is signed here
# with a throwaway key and checked against that key's public half.
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$t/rsa.pem" 2>/dev/null
openssl pkey -in "$t/rsa.pem" -pubout -out "$t/rsa.pub" 2>/dev/null
python3 - "$t" <<'PY' || fail "the sign-in token is not a valid RS256 JWT"
import base64, json, pathlib, subprocess, sys, time
sys.path.insert(0, "tool")
import play_publish

t = pathlib.Path(sys.argv[1])
key = {"client_email": "bot@example.iam.gserviceaccount.com",
       "private_key": (t / "rsa.pem").read_text(),
       "token_uri": "https://oauth2.googleapis.com/token"}
header, claims, signature = play_publish.assertion(key).split(".")
pad = lambda s: base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
assert json.loads(pad(header)) == {"alg": "RS256", "typ": "JWT"}, pad(header)
body = json.loads(pad(claims))
assert body["iss"] == key["client_email"], body
assert body["aud"] == key["token_uri"], body
assert body["scope"] == play_publish.SCOPE, body
assert body["iat"] <= time.time() + 1 < body["exp"], body
(t / "sig").write_bytes(pad(signature))
subprocess.run(["openssl", "dgst", "-sha256", "-verify", t / "rsa.pub",
                "-signature", t / "sig"],
               input=f"{header}.{claims}".encode(), check=True,
               stdout=subprocess.DEVNULL)
PY

echo "tool/play_publish.py: every refusal checked, the sign-in token verified,"
echo "and no key printed"
