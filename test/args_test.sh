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

echo "config flags"

parse_args "--env --name --db --port" "--force" \
  --env staging --name stg --db sc-adam-rds --port 15433 --force
assert_eq "stg" "$ARG_NAME" "value flag --name"
assert_eq "sc-adam-rds" "$ARG_DB" "value flag --db"
assert_eq "15433" "$ARG_PORT" "value flag --port"
assert_eq "1" "$ARG_FORCE" "boolean flag --force"

assert_status 1 "--name is not an ssh flag" parse_args "--env --app" "" --name stg
assert_status 1 "--port is not an ssh flag" parse_args "--env --app" "" --port 15433

# ALL_ARG_FLAGS drives the clearing loop, so a flag missing from that list keeps
# its value into the next call.
parse_args "--env --name --port" "--force" --env staging --name stg --port 15433 --force
parse_args "--env --name --port" "--force" --env staging
assert_eq "" "$ARG_NAME" "--name is cleared between calls"
assert_eq "" "$ARG_PORT" "--port is cleared between calls"
assert_eq "" "$ARG_FORCE" "--force is cleared between calls"

echo "validate_port"

assert_status 0 "lowest valid port" validate_port 1
assert_status 0 "port in range" validate_port 15432
assert_status 0 "highest valid port" validate_port 65535
assert_status 1 "port zero" validate_port 0
assert_status 1 "port above range" validate_port 65536
assert_contains "1-65535" "$LAST_OUTPUT" "port error names the valid range"
assert_status 1 "non-numeric port" validate_port abc
assert_status 1 "negative port" validate_port -5
assert_status 1 "port with a decimal point" validate_port 154.32
assert_status 1 "empty port" validate_port ""

echo "config file helpers"

# These helpers write to CONFIG_FILE, so point it at a throwaway fixture.
CONFIG_FIXTURE=$(mktemp)
CONFIG_FILE="$CONFIG_FIXTURE"
reset_fixture() {
  cat > "$CONFIG_FILE" <<'JSON'
{
  "staging": {
    "profile": "sc-staging",
    "region": "ap-southeast-5",
    "databases": { "sc-staging-adam-rds": 15432 }
  },
  "production": {
    "profile": "sc-prod",
    "region": "ap-southeast-1",
    "databases": {}
  }
}
JSON
}
reset_fixture

assert_status 0 "existing account is found" config_account_exists staging
assert_status 1 "missing account is not found" config_account_exists nope

reset_fixture
config_rename_account staging stg >/dev/null
assert_eq "sc-staging" "$(load_config stg profile)" "rename carries the profile over"
assert_eq "ap-southeast-5" "$(load_config stg region)" "rename carries the region over"
assert_eq "15432" "$(jq -r '.stg.databases["sc-staging-adam-rds"]' "$CONFIG_FILE")" \
  "rename carries the db port map over"
assert_status 1 "the old name is gone after a rename" config_account_exists staging

reset_fixture
assert_status 1 "rename onto an existing account is refused" \
  config_rename_account staging production
assert_contains "already exists" "$LAST_OUTPUT" "rename collision message"
assert_eq "sc-prod" "$(load_config production profile)" "a refused rename leaves the target alone"

reset_fixture
config_set_db_port staging new-rds 15440 >/dev/null
assert_eq "15440" "$(jq -r '.staging.databases["new-rds"]' "$CONFIG_FILE")" "sets a new db port"
# find_free_port scans the config for numbers, so a port stored as a string
# would silently drop out of collision avoidance.
assert_eq "number" "$(jq -r '.staging.databases["new-rds"] | type' "$CONFIG_FILE")" \
  "port is stored as a number, not a string"

# A leading zero is not valid JSON on its own, so the port is normalised to a
# canonical decimal before it reaches jq --argjson.
config_set_db_port staging zero-padded 015441 >/dev/null
assert_eq "15441" "$(jq -r '.staging.databases["zero-padded"]' "$CONFIG_FILE")" \
  "a zero-padded port is normalised"

config_set_db_port staging sc-staging-adam-rds 15999 >/dev/null
assert_eq "15999" "$(jq -r '.staging.databases["sc-staging-adam-rds"]' "$CONFIG_FILE")" \
  "overwrites an existing db port"

reset_fixture
config_unset_db_port staging sc-staging-adam-rds >/dev/null
assert_eq "null" "$(jq -r '.staging.databases["sc-staging-adam-rds"]' "$CONFIG_FILE")" \
  "unsets a db port"
assert_status 0 "unsetting a port leaves the account in place" config_account_exists staging

reset_fixture
assert_status 1 "unsetting an unknown db is refused" config_unset_db_port staging nope
assert_contains "no port assignment" "$LAST_OUTPUT" "unknown db message"

rm -f "$CONFIG_FIXTURE"

echo "version"

assert_eq "dev" "$(script_version "$HERE/../ssm.sh")" "the repository copy is unstamped"
assert_eq "ssm dev" "$(bash "$HERE/../ssm.sh" version)" "ssm version"
assert_eq "ssm dev" "$(bash "$HERE/../ssm.sh" --version)" "ssm --version"
assert_status 1 "ssm version takes no flags" bash "$HERE/../ssm.sh" version --env staging

VERSION_FIXTURE=$(mktemp)
printf '#!/bin/bash\necho old\n' > "$VERSION_FIXTURE"
assert_eq "unknown" "$(script_version "$VERSION_FIXTURE")" "a script from before versioning"
assert_eq "unknown" "$(script_version "$VERSION_FIXTURE.missing")" "a missing file"
rm -f "$VERSION_FIXTURE"

echo "uninstall"

parse_args "" "--yes --purge --with-deps" --purge --with-deps
assert_eq "1" "$ARG_PURGE" "boolean flag --purge"
assert_eq "1" "$ARG_WITH_DEPS" "boolean flag --with-deps"
parse_args "" "--yes --purge --with-deps" --yes
assert_eq "" "$ARG_PURGE" "--purge is cleared between calls"
assert_eq "" "$ARG_WITH_DEPS" "--with-deps is cleared between calls"

# Nothing here may touch the real machine: every path points into a scratch
# directory, and brew and sudo are stubbed to record what they were asked to do.
# The sudo stub always fails, so an unexpected escalation cannot succeed.
UNINSTALL_ROOT=$(mktemp -d)
CALLS="$UNINSTALL_ROOT/calls"
BREW_INSTALLED=""
brew() {
  echo "brew $*" >> "$CALLS"
  if [[ "$1" == "list" ]]; then
    [[ " $BREW_INSTALLED " == *" ${!#} "* ]]
  fi
}
sudo() { echo "sudo $*" >> "$CALLS"; return 1; }

reset_uninstall_fixture() {
  chmod -R u+w "$UNINSTALL_ROOT" 2>/dev/null
  rm -rf "$UNINSTALL_ROOT/home" "$UNINSTALL_ROOT/bin" "$UNINSTALL_ROOT/aws-cli" \
    "$UNINSTALL_ROOT/plugin"
  : > "$CALLS"
  SSM_DIR="$UNINSTALL_ROOT/home/.ssm"
  SSM_SCRIPT="$SSM_DIR/ssm.sh"
  UNINSTALL_BIN_DIR="$UNINSTALL_ROOT/bin"
  SSM_SYMLINK="$UNINSTALL_BIN_DIR/ssm"
  AWS_CLI_DIR="$UNINSTALL_ROOT/aws-cli"
  SSM_PLUGIN_DIR="$UNINSTALL_ROOT/plugin"
  BREW_INSTALLED=""
  mkdir -p "$SSM_DIR" "$UNINSTALL_BIN_DIR"
  echo '#!/bin/bash' > "$SSM_SCRIPT"
  ln -s "$SSM_SCRIPT" "$SSM_SYMLINK"
}

assert_gone() {
  if [[ ! -e "$1" && ! -L "$1" ]]; then pass; else fail "$2: '$1' still exists"; fi
}
assert_present() {
  if [[ -e "$1" || -L "$1" ]]; then pass; else fail "$2: '$1' is missing"; fi
}
optional_keys() { uninstall_optional_rows | cut -f1 | tr '\n' ' '; }

reset_uninstall_fixture
assert_eq "" "$(optional_keys)" "a bare install offers nothing optional"

reset_uninstall_fixture
echo '{}' > "$SSM_DIR/config.json"
BREW_INSTALLED="jq"
mkdir -p "$AWS_CLI_DIR"
assert_eq "config jq aws-cli " "$(optional_keys)" "only what is present is offered"

reset_uninstall_fixture
echo 'apiVersion: v1' > "$SSM_DIR/kubeconfig"
BREW_INSTALLED="fzf jq kubernetes-cli"
mkdir -p "$AWS_CLI_DIR" "$SSM_PLUGIN_DIR"
assert_eq "config fzf jq kubernetes-cli aws-cli session-manager-plugin " "$(optional_keys)" \
  "everything present is offered, in install order"

ROWS=("config	~/.ssm" "fzf	fzf" "aws-cli	AWS CLI v2")
flagged() { uninstall_flagged_keys "$@" | tr '\n' ' '; }
parse_args "" "--yes --purge --with-deps" --yes
assert_eq "" "$(flagged "${ROWS[@]}")" "--yes alone removes nothing optional"
parse_args "" "--yes --purge --with-deps" --yes --with-deps
assert_eq "fzf aws-cli " "$(flagged "${ROWS[@]}")" "--with-deps selects dependencies, not config"
parse_args "" "--yes --purge --with-deps" --purge
assert_eq "config " "$(flagged "${ROWS[@]}")" "--purge selects config, not dependencies"
parse_args "" "--yes --purge --with-deps" --purge --with-deps
assert_eq "config fzf aws-cli " "$(flagged "${ROWS[@]}")" "--purge --with-deps selects both"

# fzf --multi prints the row under the cursor when Enter is pressed with nothing
# marked, so a checklist whose first row is a real item would remove it. This
# stub does exactly that.
fzf() { head -1; }
out=$(select_multi "Also remove?" "header" "config	~/.ssm" "jq	jq")
assert_eq "" "$out" "Enter with nothing marked selects nothing"
fzf() { grep -v '^none'; }
out=$(select_multi "Also remove?" "header" "config	~/.ssm" "jq	jq")
assert_eq "config
jq" "$out" "marked rows come back as their keys"
unset -f fzf

out=$(printf 'n\ny\n' | PATH="$UNINSTALL_ROOT/empty" select_multi "Also remove?" "header" \
  "config	~/.ssm" "jq	jq" 2>/dev/null)
assert_eq "jq" "$out" "without fzf each row is asked as a y/N question"

reset_uninstall_fixture
uninstall_core >/dev/null 2>&1
assert_gone "$SSM_SCRIPT" "core removes the script"
assert_gone "$SSM_SYMLINK" "core removes our symlink"
assert_gone "$SSM_DIR" "core removes ~/.ssm once nothing else is in it"

reset_uninstall_fixture
echo '{}' > "$SSM_DIR/config.json"
uninstall_core >/dev/null 2>&1
assert_present "$SSM_DIR/config.json" "core keeps the config"

reset_uninstall_fixture
rm "$SSM_SYMLINK"
ln -s /usr/bin/true "$SSM_SYMLINK"
out=$(uninstall_core 2>&1)
assert_present "$SSM_SYMLINK" "a symlink to some other ssm is left alone"
assert_contains "$SSM_SYMLINK" "$out" "the untouched symlink is reported"

reset_uninstall_fixture
chmod a-w "$UNINSTALL_BIN_DIR"
uninstall_core >/dev/null 2>&1
assert_contains "$SSM_SYMLINK" "$(grep '^sudo rm' "$CALLS")" \
  "a symlink the user cannot remove is retried with sudo"
chmod u+w "$UNINSTALL_BIN_DIR"

reset_uninstall_fixture
echo '{}' > "$SSM_DIR/config.json"
uninstall_remove config >/dev/null 2>&1
assert_gone "$SSM_DIR" "removing config deletes ~/.ssm"

reset_uninstall_fixture
uninstall_remove kubernetes-cli >/dev/null 2>&1
assert_contains "brew uninstall kubernetes-cli" "$(cat "$CALLS")" "a brew dependency is brew-uninstalled"

reset_uninstall_fixture
mkdir -p "$AWS_CLI_DIR"
touch "$AWS_CLI_DIR/aws" "$AWS_CLI_DIR/aws_completer"
ln -s "$AWS_CLI_DIR/aws" "$UNINSTALL_BIN_DIR/aws"
ln -s "$AWS_CLI_DIR/aws_completer" "$UNINSTALL_BIN_DIR/aws_completer"
uninstall_remove aws-cli >/dev/null 2>&1
assert_gone "$AWS_CLI_DIR" "removing the AWS CLI deletes its install directory"
assert_gone "$UNINSTALL_BIN_DIR/aws" "removing the AWS CLI deletes the aws link"
assert_gone "$UNINSTALL_BIN_DIR/aws_completer" "removing the AWS CLI deletes the aws_completer link"

reset_uninstall_fixture
mkdir -p "$AWS_CLI_DIR"
ln -s /opt/homebrew/bin/aws "$UNINSTALL_BIN_DIR/aws"
uninstall_remove aws-cli >/dev/null 2>&1
assert_present "$UNINSTALL_BIN_DIR/aws" "an aws link into another install is left alone"

reset_uninstall_fixture
mkdir -p "$SSM_PLUGIN_DIR/bin"
touch "$SSM_PLUGIN_DIR/bin/session-manager-plugin"
ln -s "$SSM_PLUGIN_DIR/bin/session-manager-plugin" "$UNINSTALL_BIN_DIR/session-manager-plugin"
uninstall_remove session-manager-plugin >/dev/null 2>&1
assert_gone "$SSM_PLUGIN_DIR" "removing the plugin deletes its install directory"
assert_gone "$UNINSTALL_BIN_DIR/session-manager-plugin" "removing the plugin deletes its link"

reset_uninstall_fixture
printf 'n\n' | cmd_uninstall >/dev/null 2>&1
assert_present "$SSM_SCRIPT" "declining the confirmation removes nothing"

reset_uninstall_fixture
echo '{}' > "$SSM_DIR/config.json"
BREW_INSTALLED="jq"
mkdir -p "$AWS_CLI_DIR"
(cmd_uninstall --yes </dev/null >/dev/null 2>&1)
assert_gone "$SSM_SCRIPT" "--yes removes the script"
assert_present "$SSM_DIR/config.json" "--yes keeps the config"
assert_present "$AWS_CLI_DIR" "--yes keeps the AWS CLI"
case "$(cat "$CALLS")" in
  *"brew uninstall"*) fail "--yes must not uninstall brew packages" ;;
  *) pass ;;
esac

reset_uninstall_fixture
echo '{}' > "$SSM_DIR/config.json"
BREW_INSTALLED="jq"
mkdir -p "$AWS_CLI_DIR"
(cmd_uninstall --yes --purge --with-deps </dev/null >/dev/null 2>&1)
assert_gone "$SSM_DIR" "--purge removes ~/.ssm"
assert_gone "$AWS_CLI_DIR" "--with-deps removes the AWS CLI"
assert_contains "brew uninstall jq" "$(cat "$CALLS")" "--with-deps brew-uninstalls jq"

# jq may already be gone by the time someone uninstalls, and uninstall does not
# need it. tr (parse_args) and cat (the usage text) are the only external
# commands --help runs.
NOJQ_BIN="$UNINSTALL_ROOT/nojq"
mkdir -p "$NOJQ_BIN"
ln -s "$(command -v tr)" "$NOJQ_BIN/tr"
ln -s "$(command -v cat)" "$NOJQ_BIN/cat"
assert_status 0 "ssm uninstall starts without jq" \
  env PATH="$NOJQ_BIN" /bin/bash "$HERE/../ssm.sh" uninstall --help

unset -f brew sudo
chmod -R u+w "$UNINSTALL_ROOT"
rm -rf "$UNINSTALL_ROOT"

echo "cmd_menu"

# The menu prints only the command name, so the dispatch block can use it
# directly. Everything else on the row is a label for the human.
fzf() { grep '^db'; }
assert_eq "db" "$(cmd_menu)" "the menu prints the key of the picked row"
fzf() { grep '^uninstall'; }
assert_eq "uninstall" "$(cmd_menu)" "a key longer than its padding is not truncated"
# fzf exits non-zero when the menu is cancelled with Esc.
fzf() { return 130; }
assert_status 1 "a cancelled menu returns 1" cmd_menu
assert_eq "" "$(cmd_menu 2>/dev/null)" "a cancelled menu prints nothing"
unset -f fzf

# Every key the menu offers has to be a command the dispatch block accepts, or
# picking it prints the usage error instead of running anything. Passing every
# row through makes cmd_menu print them all, which is the list to check.
fzf() { cat; }
menu_keys=$(cmd_menu | awk '{print $1}')
unset -f fzf
DISPATCH=$(sed -n '/^  case "\$COMMAND" in$/,/^  esac$/p' "$HERE/../ssm.sh")
for key in $menu_keys; do
  assert_contains "$key)" "$DISPATCH" "the dispatch block handles '$key'"
done

# Bare `ssm` must keep its old contract everywhere a menu cannot be drawn: a
# pipe, a redirect, or a machine without fzf. Anything scripted against it
# depends on the exit status, not on the menu.
assert_status 1 "bare ssm without a terminal still exits 1" \
  env -u COLUMNS /bin/bash -c "echo | bash '$HERE/../ssm.sh'"
assert_contains "Usage: ssm" "$LAST_OUTPUT" "bare ssm without a terminal still prints usage"
assert_status 1 "an unknown command still exits 1" \
  env /bin/bash -c "echo | bash '$HERE/../ssm.sh' nope"
assert_contains "Usage: ssm" "$LAST_OUTPUT" "an unknown command still prints usage"

echo ""
if [[ $FAILED -eq 0 ]]; then
  echo "ok — $PASSED assertions passed"
else
  echo "$FAILED of $((PASSED + FAILED)) assertions failed" >&2
  exit 1
fi
