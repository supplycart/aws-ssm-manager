#!/bin/bash
# Checks that ssm.sh and ssm.ps1 expose the same CLI.
#
# Both are parsed as files rather than run, so this needs no pwsh and no AWS,
# and it fails in the PR rather than at release time. commands.manifest is the
# source of truth; neither implementation can satisfy this alone.
#
# Run: bash test/parity_test.sh

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
MANIFEST="$ROOT/commands.manifest"
SH="$ROOT/ssm.sh"
PS="$ROOT/ssm.ps1"

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL: $1" >&2; }

assert_eq() {
  if [[ "$1" == "$2" ]]; then pass; else fail "$3: expected '$1', got '$2'"; fi
}

# Flag sets are compared as sets, so the order a command lists them in is free.
sort_flags() {
  printf '%s\n' $1 | sort | tr '\n' ' ' | sed 's/ $//'
}

manifest_commands() {
  grep -v '^#' "$MANIFEST" | grep -v '^$' | cut -f1
}

manifest_field() {
  grep -v '^#' "$MANIFEST" | awk -F'\t' -v cmd="$1" -v col="$2" '$1 == cmd { print $col }'
}

echo "commands.manifest"

COMMANDS=$(manifest_commands)
assert_eq "config db help pod ssh uninstall update version" \
  "$(sort_flags "$COMMANDS")" "the manifest lists the commands ssm has"

echo "ssm.sh matches the manifest"

# Pulls the two quoted arguments out of a command's parse_args call. cmd_config
# wraps its call onto a second line, so continuations are joined first.
sh_parse_args() {
  sed -e ':a' -e '/\\$/{N;s/\\\n//;ta' -e '}' "$SH" |
    awk -v fn="cmd_$1" '
      $0 ~ "^" fn "\\(\\) \\{" { inside = 1 }
      inside && /parse_args/ {
        line = $0
        sub(/.*parse_args[ \t]+/, "", line)
        print line
        exit
      }'
}

for cmd in $COMMANDS; do
  # help has no cmd_help parse_args call: it takes no flags and never parses.
  [[ "$cmd" == "help" ]] && continue

  call=$(sh_parse_args "$cmd")
  # The call is: "<value flags>" "<bool flags>" "$@"
  value=$(printf '%s' "$call" | awk -F'"' '{print $2}')
  bool=$(printf '%s' "$call" | awk -F'"' '{print $4}')

  assert_eq "$(sort_flags "$(manifest_field "$cmd" 2)")" "$(sort_flags "$value")" \
    "ssm.sh $cmd value flags"
  assert_eq "$(sort_flags "$(manifest_field "$cmd" 3)")" "$(sort_flags "$bool")" \
    "ssm.sh $cmd bool flags"
done

# Every command in the manifest is wired into the dispatch block, and the block
# introduces none the manifest does not know about.
DISPATCH=$(sed -n '/^  case "\$COMMAND" in$/,/^  esac$/p' "$SH")
for cmd in $COMMANDS; do
  case "$DISPATCH" in
    *"$cmd)"*) pass ;;
    *) fail "ssm.sh dispatch handles '$cmd'" ;;
  esac
done

echo "ssm.ps1 matches the manifest"

# The PowerShell side keeps its flag sets in one $SSM_COMMANDS table, which is
# why this can be parsed from bash at all. The table is flattened and then split
# so each entry is on a line of its own: without the split, a greedy match runs
# past the entry being read and picks up the last command's flags instead.
PS_ENTRIES=$(awk '
  /^\$SSM_COMMANDS = \[ordered\]@\{/ { inside = 1; next }
  inside && /^\}/ { exit }
  inside { printf "%s ", $0 }
' "$PS" | sed 's/\([a-z][a-z]*\)  *= *@{/\
&/g')

for cmd in $COMMANDS; do
  entry=$(printf '%s\n' "$PS_ENTRIES" | grep "^ *$cmd  *= *@{")
  value=$(printf '%s' "$entry" | sed -n "s/.*Value  *= *'\([^']*\)'.*/\1/p")
  bool=$(printf '%s' "$entry" | sed -n "s/.*Bool  *= *'\([^']*\)'.*/\1/p")

  assert_eq "$(sort_flags "$(manifest_field "$cmd" 2)")" "$(sort_flags "$value")" \
    "ssm.ps1 $cmd value flags"
  assert_eq "$(sort_flags "$(manifest_field "$cmd" 3)")" "$(sort_flags "$bool")" \
    "ssm.ps1 $cmd bool flags"
done

PS_DISPATCH=$(sed -n "/switch -CaseSensitive (\$script:COMMAND)/,/^    }$/p" "$PS")
for cmd in $COMMANDS; do
  case "$PS_DISPATCH" in
    *"'$cmd'"*) pass ;;
    *) fail "ssm.ps1 dispatch handles '$cmd'" ;;
  esac
done

echo "the version stamp"

# deploy.yml stamps both files, and stamp_version insists on exactly one line.
# Failing here beats failing in the release job.
assert_eq "1" "$(grep -cFx 'SSM_VERSION="dev"' "$SH")" "ssm.sh has one version stamp"
assert_eq "1" "$(grep -cFx "\$SSM_VERSION = 'dev'" "$PS")" "ssm.ps1 has one version stamp"

echo "the CDN base"

# CLAUDE.md records these as hard-coded in an exact set of files. That rule was
# prose until now; this is what holds it.
CDN="https://cdn.supplycart.my/shells/aws-ssm-manager"
count_cdn() { grep -cF "$CDN" "$1" 2>/dev/null || echo 0; }

assert_eq "1" "$(count_cdn "$PS")" "ssm.ps1 names the CDN once"
assert_eq "1" "$(count_cdn "$ROOT/ssm.sh")" "ssm.sh names the CDN once"

echo "the docs match the manifest"

for cmd in $COMMANDS; do
  page="$ROOT/docs/src/commands/$cmd.md"
  # Only ssh/pod/db/config/uninstall have a page of their own; the rest live in
  # the overview.
  [[ -f "$page" ]] || page="$ROOT/docs/src/commands/overview.md"

  for flag in $(manifest_field "$cmd" 2) $(manifest_field "$cmd" 3); do
    if grep -qF -- "$flag" "$page"; then pass; else
      fail "docs for '$cmd' mention $flag (looked in ${page#"$ROOT/"})"
    fi
  done
done

echo ""
if [[ $FAILED -eq 0 ]]; then
  echo "ok — $PASSED assertions passed"
else
  echo "$FAILED of $((PASSED + FAILED)) assertions failed" >&2
  exit 1
fi
