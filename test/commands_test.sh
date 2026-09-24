#!/usr/bin/env bash
# Runs the commands themselves -- every one in commands.manifest, through both
# ssm.sh and ssm.ps1 -- and checks what they print and what they exit with.
#
# The other suites test helpers in isolation: they source the script and call a
# function. Nothing called a command end to end, which is how v1.2.5 shipped a
# Windows build where `ssm config` answered "Unknown option ''" and every
# account command died on an empty config.json.
#
# The AWS CLI, kubectl, fzf and sudo are stubs in test/stubs, on PATH ahead of
# anything real, so a case is deterministic and touches nothing outside its own
# scratch HOME. Each case runs against both implementations and asserts the
# same exit code and the same text from each, which is what keeps the two from
# drifting in behaviour rather than only in flag names.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUBS="$ROOT/test/stubs"
PASSED=0
FAILED=0

PWSH=""
if command -v pwsh >/dev/null 2>&1; then PWSH="pwsh"; fi

pass() { PASSED=$((PASSED + 1)); }
fail() {
  FAILED=$((FAILED + 1))
  echo "  FAIL: $1" >&2
  [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/        /' >&2
  return 0
}

# A HOME of its own per case: config.json, the kubeconfig ssm pod writes, and
# the stub's record of `aws configure` all live under it.
# CASE_AWS_CREDENTIALS / CASE_AWS_CONFIG, when set, become ~/.aws/credentials
# and ~/.aws/config there, which is where the key hints and the profile picker
# read from.
new_home() {
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/ssm-cmd-XXXXXX")
  mkdir -p "$dir/.ssm"
  printf '%s\n' "${1:-\{\}}" > "$dir/.ssm/config.json"
  if [[ -n "${CASE_AWS_CREDENTIALS:-}${CASE_AWS_CONFIG:-}" ]]; then
    mkdir -p "$dir/.aws"
    [[ -n "${CASE_AWS_CREDENTIALS:-}" ]] && printf '%s\n' "$CASE_AWS_CREDENTIALS" > "$dir/.aws/credentials"
    [[ -n "${CASE_AWS_CONFIG:-}" ]] && printf '%s\n' "$CASE_AWS_CONFIG" > "$dir/.aws/config"
  fi
  echo "$dir"
}

# The developer's own AWS settings must not leak into a case.
unset AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE AWS_PROFILE

FIXTURE='{
  "staging": {
    "profile": "sc-staging",
    "region": "ap-southeast-5",
    "db": { "adam-db": 15432 }
  },
  "production": {
    "profile": "sc-prod",
    "region": "ap-southeast-1"
  }
}'

# The region picker fetches its list over HTTP. A local server hands out a
# fixture in the same shape, so no case touches the network: two open regions,
# one announced without a code yet (never offered), and one in another
# partition.
REGIONS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ssm-regions-XXXXXX")
cat > "$REGIONS_DIR/data.json" <<'JSON'
{
  "count": 4,
  "regions": [
    { "code": "ap-southeast-1", "name": "Asia Pacific (Singapore)", "partition": "aws", "available": true },
    { "code": "ap-southeast-5", "name": "Asia Pacific (Malaysia)", "partition": "aws", "available": true },
    { "code": "", "name": "Kingdom of Saudi Arabia", "partition": "", "available": false },
    { "code": "eusc-de-east-1", "name": "AWS European Sovereign Cloud (Germany)", "partition": "aws-eusc", "available": true }
  ]
}
JSON
python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$REGIONS_DIR" \
  > "$REGIONS_DIR/server.log" 2>&1 &
REGIONS_PID=$!
# Not a job of this shell any more, so stopping it prints no "Terminated".
disown "$REGIONS_PID"
trap 'kill "$REGIONS_PID" 2>/dev/null; rm -rf "$REGIONS_DIR"' EXIT
REGIONS_PORT=""
for _ in $(seq 1 50); do
  REGIONS_PORT=$(sed -n 's/.*port \([0-9][0-9]*\).*/\1/p' "$REGIONS_DIR/server.log" | head -1)
  [[ -n "$REGIONS_PORT" ]] && break
  sleep 0.1
done
[[ -n "$REGIONS_PORT" ]] || { echo "could not start the region fixture server" >&2; exit 1; }
export SSM_REGIONS_URL="http://127.0.0.1:$REGIONS_PORT/data.json"

# run <impl> <home> <args...>  -- stdout and stderr together, exit code in RUN_RC.
# Both streams, because the two implementations agree on what a message says but
# a prompt's stream is a platform detail (PowerShell prompts have to go to the
# host, never the success stream).
RUN_OUT=""
RUN_RC=0
run() {
  local impl="$1" home="$2"
  shift 2
  local out rc
  # A scratch hosts file for every case, so an `ssm db` that gets as far as
  # the tunnel never reads or writes the real one.
  touch "$home/hosts"
  if [[ "$impl" == bash ]]; then
    out=$(HOME="$home" PATH="$STUBS:$PATH" SSM_HOSTS_FILE="$home/hosts" \
      SSM_TEST_MENU_LOG="$home/menu.log" bash "$ROOT/ssm.sh" "$@" 2>&1 </dev/null)
    rc=$?
  else
    out=$(HOME="$home" PATH="$STUBS:$PATH" SSM_TEST_MENU_LOG="$home/menu.log" \
      "$PWSH" -NoProfile -File "$ROOT/ssm.ps1" "$@" 2>&1 </dev/null)
    rc=$?
  fi
  RUN_OUT="$out"
  RUN_RC=$rc
}

# case_both <name> <expected-rc> <expected-substring> [-- <args...>]
# The same case against both implementations. An empty substring checks only
# the exit code.
case_both() {
  local name="$1" want_rc="$2" want_text="$3"
  shift 3
  local config="${CASE_CONFIG:-$FIXTURE}"
  local impl home
  for impl in bash pwsh; do
    [[ "$impl" == pwsh && -z "$PWSH" ]] && continue
    home=$(new_home "$config")
    run "$impl" "$home" "$@"
    if [[ "$RUN_RC" -ne "$want_rc" ]]; then
      fail "$name [$impl]: exit $RUN_RC, wanted $want_rc" "$RUN_OUT"
    else
      pass
    fi
    if [[ -n "$want_text" ]]; then
      if [[ "$RUN_OUT" == *"$want_text"* ]]; then pass; else
        fail "$name [$impl]: no '$want_text' in the output" "$RUN_OUT"
      fi
    fi
    # CASE_MENU_WANT: a row some menu in this run must have offered.
    if [[ -n "${CASE_MENU_WANT:-}" ]]; then
      if grep -qxF -- "$CASE_MENU_WANT" "$home/menu.log" 2>/dev/null; then pass; else
        fail "$name [$impl]: no menu offered '$CASE_MENU_WANT'" "$(cat "$home/menu.log" 2>&1)"
      fi
    fi
    rm -rf "$home"
  done
}

# case_config <name> <starting-config> <args...>
# Runs the command in both, then compares the config.json each one produced.
# Byte-for-byte after normalising, since a db port written as a string instead
# of a number silently drops out of collision avoidance.
case_config() {
  local name="$1" config="$2"
  shift 2
  [[ -z "$PWSH" ]] && return 0
  local bash_home pwsh_home bash_json pwsh_json
  bash_home=$(new_home "$config")
  pwsh_home=$(new_home "$config")
  run bash "$bash_home" "$@"
  local bash_rc="$RUN_RC" bash_out="$RUN_OUT"
  run pwsh "$pwsh_home" "$@"
  if [[ "$bash_rc" -ne "$RUN_RC" ]]; then
    fail "$name: exit $bash_rc (bash) vs $RUN_RC (pwsh)" "$bash_out
--- pwsh:
$RUN_OUT"
  else
    pass
  fi
  bash_json=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True))' "$bash_home/.ssm/config.json" 2>&1)
  pwsh_json=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True))' "$pwsh_home/.ssm/config.json" 2>&1)
  if [[ "$bash_json" == "$pwsh_json" ]]; then pass; else
    fail "$name: the two wrote different config.json" "bash: $bash_json
pwsh: $pwsh_json"
  fi
  rm -rf "$bash_home" "$pwsh_home"
}

echo "test/commands_test.sh"
if [[ -z "$PWSH" ]]; then
  echo "  (pwsh not on this machine: the bash half only)"
fi

# ---------------------------------------------------------------------------
echo "help and version"
# ---------------------------------------------------------------------------
case_both 'help' 0 'ssm ssh' help
case_both 'help lists every command' 0 'ssm uninstall' help
case_both '-h' 0 'ssm ssh' -h
case_both '--help' 0 'ssm ssh' --help
case_both 'version' 0 'ssm ' version
case_both '--version' 0 'ssm ' --version
case_both 'an unknown command' 1 'Usage: ssm' frobnicate
case_both 'an unknown command names help' 1 "ssm help" frobnicate

for cmd in ssh pod db config update uninstall; do
  case_both "$cmd --help" 0 "ssm $cmd" "$cmd" --help
done

# ---------------------------------------------------------------------------
echo "argument handling"
# ---------------------------------------------------------------------------
case_both 'an unknown flag' 1 "Unknown option '--nope'" ssh --nope
case_both 'an unknown flag names the command' 1 'ssm ssh' ssh --nope
case_both 'a flag another command owns' 1 "Unknown option '--db'" ssh --db x
case_both 'flags are case-sensitive' 1 "Unknown option '--ENV'" ssh --ENV staging
case_both 'a missing flag value' 1 "--env" ssh --env
case_both '--flag=value is accepted' 1 "no account 'nosuch'" ssh --env=nosuch
case_both 'an unknown config action' 1 "unknown config action 'bogus'" config bogus
case_both 'a config action still takes flags' 0 'staging' config view --env staging

# ---------------------------------------------------------------------------
echo "an empty config"
# ---------------------------------------------------------------------------
# What every fresh install has: install.ps1 and install.sh both write {}.
CASE_CONFIG='{}'
case_both 'ssh says there are no accounts' 1 'No accounts found' ssh
case_both 'db says there are no accounts' 1 'No accounts found' db
case_both 'pod says there are no accounts' 1 'No accounts found' pod
# `config view` on an empty config prints the empty document, as `jq .` does.
case_both 'config view on an empty config' 0 '{}' config view
case_both 'config edit says there are no accounts' 1 'No accounts found' config edit
case_both 'config delete says there are no accounts' 1 'No accounts found' config delete
# The one command that has to work on an empty config -- it is how an account
# gets there. No --env, so it asks; the fzf stub cancels, which is exit 0.
case_both 'bare config offers the menu' 0 '' config
unset CASE_CONFIG

# ---------------------------------------------------------------------------
echo "selection"
# ---------------------------------------------------------------------------
case_both 'an account that is not there' 1 "no account 'nosuch'" ssh --env nosuch
case_both 'the candidates are listed' 1 'staging' ssh --env nosuch
case_both 'an app that is not there' 1 "no app 'nosuch'" ssh --env staging --app nosuch
case_both 'a single instance is auto-selected' 0 'Instance: i-0adam000000000001 adam-web-1 (only one)' \
  ssh --env staging --app adam
case_both 'and the session is started' 0 'STUB session to i-0adam000000000001' ssh --env staging --app adam
case_both 'a named instance' 0 'STUB session to i-0bea000000000002' ssh --env staging --app beatrice --instance bea-web-2
case_both 'an instance that is not there' 1 "no instance 'nosuch'" ssh --env staging --app beatrice --instance nosuch
# Cancelling is not success: bash's pick_* returns 1 and the caller exits 1.
case_both 'cancelling a menu exits 1' 1 '' ssh --env staging --app beatrice

# ---------------------------------------------------------------------------
echo "ssm db"
# ---------------------------------------------------------------------------
case_both 'a database that is not there' 1 "no database 'nosuch'" db --env staging --app adam --db nosuch
case_both 'an app with no databases' 1 'No RDS instances' db --env staging --app charlie
case_both 'a bad --port is refused' 1 'port' db --env staging --app adam --port 99999
case_both 'a bad --port is refused before AWS' 1 'port' db --env staging --app adam --port abc

# ---------------------------------------------------------------------------
echo "ssm db and the hosts file (macOS only)"
# ---------------------------------------------------------------------------
# ssm.ps1 never edits the hosts file (platforms.md), so these run bash only.
# SSM_HOSTS_FILE points ssm.sh at a scratch copy, and SSM_TEST_SUDO_EXEC makes
# the sudo stub actually run the edit, so what ssm left behind is checked byte
# for byte.
#
# The bug these pin: the EXIT trap read $DB_ALIAS, a local of cmd_db, after
# cmd_db had returned -- so it was empty, and `sed "/127.0.0.1 $DB_ALIAS/d"`
# became `sed "/127.0.0.1 /d"`, deleting every 127.0.0.1 line in the file.
HOSTS_FIXTURE='##
# Host Database
127.0.0.1	localhost
127.0.0.1 myapp.test
127.0.0.1 adam-db.tunnel.local
127.0.0.1 adam-db-replica.tunnel
255.255.255.255	broadcasthost
::1             localhost'
TAGGED='127.0.0.1 adam-db.tunnel # ssm-tunnel'

# hosts_run <hosts-content> -- runs `ssm db` for adam against that hosts file.
# Leaves the scratch HOME in HOSTS_HOME for the assertions; the caller removes it.
HOSTS_HOME=""
hosts_run() {
  HOSTS_HOME=$(new_home "$FIXTURE")
  printf '%s\n' "$1" > "$HOSTS_HOME/hosts"
  RUN_OUT=$(HOME="$HOSTS_HOME" PATH="$STUBS:$PATH" SSM_HOSTS_FILE="$HOSTS_HOME/hosts" \
    SSM_TEST_SUDO_EXEC=1 bash "$ROOT/ssm.sh" db --env staging --app adam 2>&1 </dev/null)
  RUN_RC=$?
}

hosts_run "$HOSTS_FIXTURE"
if [[ "$RUN_RC" -eq 0 && "$RUN_OUT" == *'STUB session to i-0adam'* ]]; then pass; else
  fail "hosts: the tunnel opened (exit $RUN_RC)" "$RUN_OUT"
fi
if grep -qxF "$TAGGED" "$HOSTS_HOME/hosts-during-session" 2>/dev/null; then pass; else
  fail "hosts: the tagged line was there while the tunnel was up" \
    "$(cat "$HOSTS_HOME/hosts-during-session" 2>&1)"
fi
if [[ "$(cat "$HOSTS_HOME/hosts")" == "$HOSTS_FIXTURE" ]]; then pass; else
  fail "hosts: every other line survives the tunnel closing" \
    "$(diff <(printf '%s\n' "$HOSTS_FIXTURE") "$HOSTS_HOME/hosts")"
fi
rm -rf "$HOSTS_HOME"

# A line the user wrote themselves is theirs: not duplicated, not removed.
hosts_run "$HOSTS_FIXTURE
127.0.0.1 adam-db.tunnel"
if [[ "$(cat "$HOSTS_HOME/hosts")" == "$HOSTS_FIXTURE
127.0.0.1 adam-db.tunnel" ]]; then pass; else
  fail "hosts: a user's own entry for the alias is left alone" \
    "$(cat "$HOSTS_HOME/hosts")"
fi
if grep -qxF "$TAGGED" "$HOSTS_HOME/hosts-during-session" 2>/dev/null; then
  fail "hosts: no tagged duplicate is added next to the user's entry"
else pass; fi
rm -rf "$HOSTS_HOME"

# Another tunnel still using the alias: its lease is live, so the line stays.
sleep 60 &
LIVE_PID=$!
HOSTS_HOME=$(new_home "$FIXTURE")
mkdir -p "$HOSTS_HOME/.ssm/tunnels"
touch "$HOSTS_HOME/.ssm/tunnels/adam-db.tunnel.$LIVE_PID"
printf '%s\n%s\n' "$HOSTS_FIXTURE" "$TAGGED" > "$HOSTS_HOME/hosts"
RUN_OUT=$(HOME="$HOSTS_HOME" PATH="$STUBS:$PATH" SSM_HOSTS_FILE="$HOSTS_HOME/hosts" \
  SSM_TEST_SUDO_EXEC=1 bash "$ROOT/ssm.sh" db --env staging --app adam 2>&1 </dev/null)
if grep -qxF "$TAGGED" "$HOSTS_HOME/hosts"; then pass; else
  fail "hosts: a line another running tunnel uses is kept" "$RUN_OUT"
fi
if [[ "$(grep -cxF "$TAGGED" "$HOSTS_HOME/hosts")" -eq 1 ]]; then pass; else
  fail "hosts: the shared line is not added twice" "$(cat "$HOSTS_HOME/hosts")"
fi
kill "$LIVE_PID" 2>/dev/null
wait "$LIVE_PID" 2>/dev/null
rm -rf "$HOSTS_HOME"

# A lease left by a tunnel that was killed outright: its pid is gone, so it is
# pruned and the line is removed with the last live tunnel.
HOSTS_HOME=$(new_home "$FIXTURE")
mkdir -p "$HOSTS_HOME/.ssm/tunnels"
touch "$HOSTS_HOME/.ssm/tunnels/adam-db.tunnel.999999"
printf '%s\n%s\n' "$HOSTS_FIXTURE" "$TAGGED" > "$HOSTS_HOME/hosts"
RUN_OUT=$(HOME="$HOSTS_HOME" PATH="$STUBS:$PATH" SSM_HOSTS_FILE="$HOSTS_HOME/hosts" \
  SSM_TEST_SUDO_EXEC=1 bash "$ROOT/ssm.sh" db --env staging --app adam 2>&1 </dev/null)
if [[ "$(cat "$HOSTS_HOME/hosts")" == "$HOSTS_FIXTURE" ]]; then pass; else
  fail "hosts: a dead tunnel's lease does not keep the line" "$(cat "$HOSTS_HOME/hosts")"
fi
if [[ -z "$(ls -A "$HOSTS_HOME/.ssm/tunnels" 2>/dev/null)" ]]; then pass; else
  fail "hosts: the dead lease is pruned" "$(ls -A "$HOSTS_HOME/.ssm/tunnels")"
fi
rm -rf "$HOSTS_HOME"

# ---------------------------------------------------------------------------
echo "ssm pod"
# ---------------------------------------------------------------------------
# The kubectl stub answers with an empty cluster, so these stop at the first
# thing that is missing -- which is the point: the message has to match.
case_both 'pod with no EKS clusters' 1 '' pod --env staging
case_both 'pod rejects an unknown flag' 1 "Unknown option '--instance'" pod --env staging --instance x

# ---------------------------------------------------------------------------
echo "ssm uninstall"
# ---------------------------------------------------------------------------
# Without --yes it asks, and end-of-input is not a yes. Nothing is removed,
# which is why this is safe to run in a scratch HOME.
case_both 'uninstall asks first' 0 'Aborted' uninstall
case_both 'uninstall lists what it removes' 0 'uninstall removes' uninstall

# ---------------------------------------------------------------------------
echo "ssm config writes"
# ---------------------------------------------------------------------------
case_config 'add an account' '{}' \
  config add --env staging --profile sc-staging --region ap-southeast-5 --skip-credentials
case_config 'add refuses a duplicate' "$FIXTURE" \
  config add --env staging --profile x --region y --skip-credentials
case_config 'add --force replaces one' "$FIXTURE" \
  config add --env staging --profile x --region ap-southeast-1 --skip-credentials --force
case_config 'rename an account' "$FIXTURE" config edit --env staging --name stg
case_config 'set a region' "$FIXTURE" config edit --env staging --region ap-southeast-1
case_config 'set a db port' "$FIXTURE" config edit --env staging --db adam-db --port 15500
case_config 'set a db port on a new db' "$FIXTURE" config edit --env staging --db new-db --port 15501
case_config 'delete a db port' "$FIXTURE" config delete --env staging --db adam-db --yes
case_config 'delete an account' "$FIXTURE" config delete --env staging --yes

# ---------------------------------------------------------------------------
echo "key hints and what was selected"
# ---------------------------------------------------------------------------
export CASE_AWS_CREDENTIALS='[sc-staging]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = not-a-real-secret

[default]
aws_access_key_id=AKIADEFAULT00000WXYZ'
export CASE_AWS_CONFIG='[profile sso-dev]
sso_session = corp
region = ap-southeast-1

[sso-session corp]
sso_start_url = https://example.awsapps.com/start'

# Accounts are listed in key order: production, then staging.
CASE_MENU_WANT=$'staging\t(AKIA****MPLE)' SSM_TEST_PICK=2 \
  case_both 'the account menu shows the masked key' 0 'STUB session to i-0adam' ssh --app adam
CASE_MENU_WANT=$'production\t(no such AWS profile)' SSM_TEST_PICK=2 \
  case_both 'an account whose profile is missing says so' 0 '' ssh --app adam
SSM_TEST_PICK=2 case_both 'the picked account is shown' 0 'Account: staging (AKIA****MPLE)' ssh --app adam
case_both 'a flagged account is shown too' 0 'Account: staging (AKIA****MPLE)' ssh --env staging --app adam
case_both 'the app is shown' 0 'App: adam' ssh --env staging --app adam
SSM_TEST_PICK=2 case_both 'a picked instance is shown' 0 'Instance: i-0bea000000000002 bea-web-2' \
  ssh --env staging --app beatrice
case_both 'the database is shown' 0 'Database: adam-db adam-db.rds.amazonaws.com 5432' \
  db --env staging --app adam --db adam-db

# ---------------------------------------------------------------------------
echo "config add: region and profile pickers"
# ---------------------------------------------------------------------------
# ap-southeast-5 is row 2 of the fixture region list.
CASE_MENU_WANT=$'ap-southeast-5\tAsia Pacific (Malaysia)' SSM_TEST_PICK=2 \
  case_both 'the region menu lists names' 0 'Region: ap-southeast-5 Asia Pacific (Malaysia)' \
  config add --env qa --profile sc-staging
SSM_TEST_PICK=2 case_config 'the picked region is written' '{}' config add --env qa --profile sc-staging
# Row 3 is eusc-de-east-1: the region without a code is not offered at all.
SSM_TEST_PICK=3 case_both 'a region with no code yet is left out' 0 'Region: eusc-de-east-1' \
  config add --env qa --profile sc-staging
# Nothing listening on port 9: the list cannot be fetched, so it asks for the
# code instead, and end-of-input is not an answer.
SSM_REGIONS_URL=http://127.0.0.1:9/data.json \
  case_both 'an unreachable region list falls back to typing' 1 'Could not fetch the region list' \
  config add --env qa --profile sc-staging
case_both 'a sovereign-cloud region code is accepted' 0 "Account 'qa' added" \
  config add --env qa --profile sc-staging --region eusc-de-east-1
case_both 'a bad --region is refused' 1 "'bogus' is not an AWS region code" \
  config add --env qa --profile sc-staging --region bogus
case_both 'a region newer than the table is accepted' 0 "Account 'qa' added" \
  config add --env qa --profile sc-staging --region xx-future-9
case_both 'edit refuses a bad --region too' 1 "'bogus' is not an AWS region code" \
  config edit --env staging --region bogus
case_config 'and changes nothing' "$FIXTURE" config edit --env staging --region bogus

case_both 'a bad --profile is refused' 1 "'bad name' is not a valid AWS CLI profile name" \
  config add --env qa --profile 'bad name' --region ap-southeast-1
case_both 'an existing profile is reused without asking' 0 \
  "Using existing AWS CLI profile 'sc-staging' (AKIA****MPLE)." \
  config add --env qa --profile sc-staging --region ap-southeast-1
# Sorted: default, sc-staging, sso-dev.
CASE_MENU_WANT=$'sso-dev\t(no access key)' SSM_TEST_PICK=1 \
  case_both 'the profile menu lists every profile' 0 "Profile: default (AKIA****WXYZ)" \
  config add --env qa --region ap-southeast-1
SSM_TEST_QUERY=brand-new case_both 'a typed name is a new profile' 1 'Profile: brand-new (new)' \
  config add --env qa --region ap-southeast-1
SSM_TEST_QUERY=brand-new case_both 'a new profile asks for its keys' 1 'Aborted: no access key given.' \
  config add --env qa --region ap-southeast-1
SSM_TEST_QUERY=brand-new case_config 'and nothing is written without them' '{}' \
  config add --env qa --region ap-southeast-1
SSM_TEST_QUERY=brand-new SSM_AWS_SECRET_KEY=s3cret \
  case_both 'a new profile is created' 0 "AWS CLI profile 'brand-new' configured." \
  config add --env qa --region ap-southeast-1 --access-key AKIANEWKEY000000WXYZ
SSM_TEST_QUERY='bad name' case_both 'a typed name is validated' 1 'not a valid AWS CLI profile name' \
  config add --env qa --region ap-southeast-1
case_both 'skipping credentials for a missing profile warns' 0 "does not exist yet" \
  config add --env qa --profile nope --region ap-southeast-1 --skip-credentials
unset CASE_AWS_CREDENTIALS CASE_AWS_CONFIG

echo ""
if [[ $FAILED -eq 0 ]]; then
  echo "ok — $PASSED assertions passed"
else
  echo "$FAILED of $((PASSED + FAILED)) assertions failed" >&2
  exit 1
fi
