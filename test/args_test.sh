#!/bin/bash
# Unit tests for the argument-handling helpers in ssm.sh. These are the only
# parts of the script that are pure -- no AWS, no network, no fzf -- so they are
# the parts worth testing. Run: bash test/args_test.sh

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../ssm.sh
source "$HERE/../ssm.sh"

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL: $1" >&2; }

assert_eq() {
  if [[ "$1" == "$2" ]]; then pass; else fail "$3: expected '$1', got '$2'"; fi
}

assert_contains() {
  case "$2" in
    *"$1"*) pass ;;
    *) fail "$3: expected output to contain '$1', got '$2'" ;;
  esac
}

# Runs a command in a subshell and asserts its exit status, so a helper that
# exits non-zero does not take the test run down with it.
assert_status() {
  local expected="$1" what="$2"
  shift 2
  local out status
  out=$("$@" 2>&1)
  status=$?
  assert_eq "$expected" "$status" "$what (status)"
  LAST_OUTPUT="$out"
}

echo "parse_args"

parse_args "--env --app" "" --env staging --app adam
assert_eq "staging" "$ARG_ENV" "value flag --env"
assert_eq "adam" "$ARG_APP" "value flag --app"

parse_args "--env --app" "" --env=staging --app=adam
assert_eq "staging" "$ARG_ENV" "--flag=value form"
assert_eq "adam" "$ARG_APP" "--flag=value form"

parse_args "--env" "--host" --env staging --host
assert_eq "1" "$ARG_HOST" "boolean flag sets 1"

# A second call must not inherit the first call's values.
parse_args "--env --app" "" --env staging
assert_eq "" "$ARG_APP" "unset flags are cleared between calls"
assert_eq "" "$ARG_HOST" "boolean flags are cleared between calls"

parse_args "--env --namespace --container" "" -e staging -n default -c web
assert_eq "staging" "$ARG_ENV" "alias -e"
assert_eq "default" "$ARG_NAMESPACE" "alias -n"
assert_eq "web" "$ARG_CONTAINER" "alias -c"

parse_args "--env" "" --account staging
assert_eq "staging" "$ARG_ENV" "alias --account"

assert_status 1 "unknown flag" parse_args "--env" "" --nope x
assert_contains "Unknown option" "$LAST_OUTPUT" "unknown flag message"

assert_status 1 "flag outside this command's allow list" parse_args "--env" "" --pod mypod
assert_contains "Unknown option" "$LAST_OUTPUT" "disallowed flag message"

assert_status 1 "value flag with no value" parse_args "--env" "" --env
assert_status 1 "value flag followed by another flag" parse_args "--env --app" "" --env --app adam
assert_status 1 "boolean flag given a value" parse_args "" "--host" --host=yes

echo "resolve_selection"

ACCOUNTS=("staging" "production")

out=$(resolve_selection "staging" "account" "$CONFIG_FILE" "Select account:" 1 "" "${ACCOUNTS[@]}")
assert_eq "staging" "$out" "exact match returns the row without prompting"

assert_status 1 "no match exits 1" \
  resolve_selection "nope" "account" "config" "Select account:" 1 "" "${ACCOUNTS[@]}"
assert_contains "no account 'nope'" "$LAST_OUTPUT" "no-match message names the value"
assert_contains "staging" "$LAST_OUTPUT" "no-match message lists the candidates"

# Instances are "id<TAB>Name" and are matchable on either column.
INSTANCES=("i-0abc	web-01" "i-0def	web-02")

out=$(resolve_selection "i-0def" "instance" "app adam" "Select instance:" "1,2" auto "${INSTANCES[@]}")
assert_eq "i-0def	web-02" "$out" "matches on the id column"

out=$(resolve_selection "web-01" "instance" "app adam" "Select instance:" "1,2" auto "${INSTANCES[@]}")
assert_eq "i-0abc	web-01" "$out" "matches on the Name column"

# Only field 1 is searched here, so a field-2 value must not match.
assert_status 1 "match fields are respected" \
  resolve_selection "web-01" "instance" "app adam" "Select instance:" 1 auto "${INSTANCES[@]}"

DUPES=("task-1	php-fpm" "task-2	php-fpm")
assert_status 1 "ambiguous match exits 1" \
  resolve_selection "php-fpm" "container" "app adam" "Select container:" 2 auto "${DUPES[@]}"
assert_contains "ambiguous container 'php-fpm'" "$LAST_OUTPUT" "ambiguous message"
assert_contains "task-2" "$LAST_OUTPUT" "ambiguous message lists the matches"

out=$(resolve_selection "" "instance" "app adam" "Select instance:" 1 auto "i-0abc	web-01" 2>/dev/null)
assert_eq "i-0abc	web-01" "$out" "single candidate auto-selects when no value is given"

echo "read_secret_value"

out=$(SSM_AWS_SECRET_KEY=fromenv read_secret_value "")
assert_eq "fromenv" "$out" "env var is used when set"

out=$(SSM_AWS_SECRET_KEY=fromenv read_secret_value "-" </dev/null)
assert_eq "fromenv" "$out" "env var wins over stdin"

out=$(echo "fromstdin" | read_secret_value "-")
assert_eq "fromstdin" "$out" "'-' reads one line from stdin"

assert_status 1 "literal secret on the command line is refused" read_secret_value "AKIAsecret"
assert_contains "shell history" "$LAST_OUTPUT" "literal secret message explains why"

echo "print_tunnel_banner"

TUNNEL=(adam-prod.tunnel 15432 adam-prod.abc123.ap-southeast-1.rds.amazonaws.com 5432)

out=$(print_tunnel_banner "${TUNNEL[@]}")
assert_contains "adam-prod.tunnel" "$out" "banner shows the tunnel host"
assert_contains "15432" "$out" "banner shows the tunnel port"
assert_contains "adam-prod.abc123.ap-southeast-1.rds.amazonaws.com" "$out" "banner shows the real host"
assert_contains "5432" "$out" "banner shows the real port"
assert_contains "do NOT use" "$out" "banner says which endpoint not to use"

# Captured output is not a terminal, so nothing may be colored -- an escape
# sequence here would land in whatever file or pipe the output was sent to.
case "$out" in
  *$'\033'*) fail "banner is plain when stdout is not a tty" ;;
  *) pass ;;
esac

# LC_ALL=C is both what a non-UTF-8 terminal gets and the only way to measure the
# box: with ASCII borders every rendered column is exactly one byte.
banner_line_widths() {
  print_tunnel_banner "${TUNNEL[@]}" \
    | sed $'s/\033\\[[0-9;]*m//g' \
    | awk '{ print length($0) }'
}

widths=$(LC_ALL=C banner_line_widths | sort -u | wc -l | tr -d ' ')
assert_eq "1" "$widths" "every line of the plain box is the same width"

# Color must not move the right border: the padding has to be measured on the
# text before the escapes are wrapped around it.
widths=$(LC_ALL=C C_BOLD=$'\033[1m' C_DIM=$'\033[2m' C_GREEN=$'\033[32m' \
  C_YELLOW=$'\033[33m' C_RESET=$'\033[0m' banner_line_widths | sort -u | wc -l | tr -d ' ')
assert_eq "1" "$widths" "every line of the colored box is the same width"

# A box wider than the terminal wraps into unreadable noise, so a long value is
# truncated to fit rather than allowed to overflow.
narrow=$(LC_ALL=C COLUMNS=44 print_tunnel_banner "${TUNNEL[@]}")
widest=$(echo "$narrow" | awk '{ if (length($0) > m) m = length($0) } END { print m }')
if [[ "$widest" -le 44 ]]; then pass; else fail "narrow box: widest line is $widest, want <= 44"; fi
assert_contains "..." "$narrow" "a truncated value is marked with an ellipsis"

# A non-interactive shell reports COLUMNS=0, which must not squeeze the box down
# to its minimum width -- the real endpoint has to stay readable in a log.
wide=$(LC_ALL=C COLUMNS=0 print_tunnel_banner "${TUNNEL[@]}")
assert_contains "adam-prod.abc123.ap-southeast-1.rds.amazonaws.com:5432" "$wide" \
  "an implausible COLUMNS falls back to a full-width box"

echo ""
if [[ $FAILED -eq 0 ]]; then
  echo "ok — $PASSED assertions passed"
else
  echo "$FAILED of $((PASSED + FAILED)) assertions failed" >&2
  exit 1
fi
