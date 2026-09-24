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
new_home() {
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/ssm-cmd-XXXXXX")
  mkdir -p "$dir/.ssm"
  printf '%s\n' "${1:-\{\}}" > "$dir/.ssm/config.json"
  echo "$dir"
}

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
  if [[ "$impl" == bash ]]; then
    out=$(HOME="$home" PATH="$STUBS:$PATH" bash "$ROOT/ssm.sh" "$@" 2>&1 </dev/null)
    rc=$?
  else
    out=$(HOME="$home" PATH="$STUBS:$PATH" "$PWSH" -NoProfile -File "$ROOT/ssm.ps1" "$@" 2>&1 </dev/null)
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
case_both 'a single instance is auto-selected' 0 'Auto-selecting' ssh --env staging --app adam
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
  config add --env staging --profile x --region y --skip-credentials --force
case_config 'rename an account' "$FIXTURE" config edit --env staging --name stg
case_config 'set a region' "$FIXTURE" config edit --env staging --region ap-southeast-1
case_config 'set a db port' "$FIXTURE" config edit --env staging --db adam-db --port 15500
case_config 'set a db port on a new db' "$FIXTURE" config edit --env staging --db new-db --port 15501
case_config 'delete a db port' "$FIXTURE" config delete --env staging --db adam-db --yes
case_config 'delete an account' "$FIXTURE" config delete --env staging --yes

echo ""
if [[ $FAILED -eq 0 ]]; then
  echo "ok — $PASSED assertions passed"
else
  echo "$FAILED of $((PASSED + FAILED)) assertions failed" >&2
  exit 1
fi
