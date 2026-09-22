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

echo "help text is identical"

# The strongest parity check there is: run both and diff. Only the platform
# tokens below are allowed to differ, and they are the same list the usage
# text in ssm.ps1 was generated with. Needs pwsh, which CI has; skipped
# elsewhere so the suite still runs on a machine without it.
if command -v pwsh >/dev/null 2>&1; then
  # The normalisation is not spelled out here: it is read from the
  # PLATFORM-TOKEN lines ssm.ps1 declares and applied in reverse. A difference
  # that is not declared there fails this check, and a declared one cannot rot.
  #
  # Literal replacement, not sed: the tokens contain backslashes, dots and
  # slashes, and escaping them into a regex is how this goes quietly wrong.
  normalise_ps() {
    awk -v psfile="$PS" '
      BEGIN {
        n = 0
        while ((getline line < psfile) > 0) {
          if (line ~ /^# PLATFORM-TOKEN\t/) {
            split(line, f, "\t"); n++; mac[n] = f[2]; win[n] = f[3]
          }
        }
        close(psfile)
        if (n == 0) { print "no PLATFORM-TOKEN lines in " psfile > "/dev/stderr"; exit 1 }
      }
      {
        line = $0
        for (i = 1; i <= n; i++) {
          out = ""; rest = line
          while ((p = index(rest, win[i])) > 0) {
            out = out substr(rest, 1, p - 1) mac[i]
            rest = substr(rest, p + length(win[i]))
          }
          line = out rest
        }
        print line
      }'
  }

  if [[ "$(grep -c '^# PLATFORM-TOKEN' "$PS")" -eq 0 ]]; then
    fail "ssm.ps1 declares no PLATFORM-TOKEN lines"
  fi

  HELP_TMP=$(mktemp -d)
  for cmd in $COMMANDS ""; do
    label="${cmd:-help}"
    if [[ -z "$cmd" ]]; then
      bash "$SH" help > "$HELP_TMP/a" 2>&1
      pwsh -NoProfile -File "$PS" help > "$HELP_TMP/b" 2>&1
    else
      bash "$SH" "$cmd" --help > "$HELP_TMP/a" 2>&1
      pwsh -NoProfile -File "$PS" "$cmd" --help > "$HELP_TMP/b" 2>&1
    fi
    normalise_ps < "$HELP_TMP/b" > "$HELP_TMP/b.norm"

    # An empty side is the failure worth naming: --help output written into a
    # function's pipeline is swallowed when the exit throw unwinds past it.
    if [[ ! -s "$HELP_TMP/b.norm" ]]; then
      fail "ssm.ps1 $label --help printed nothing"
    elif diff -q "$HELP_TMP/a" "$HELP_TMP/b.norm" >/dev/null; then
      pass
    else
      fail "$label help differs between the implementations:
$(diff "$HELP_TMP/a" "$HELP_TMP/b.norm" | head -8)"
    fi
  done
  rm -rf "$HELP_TMP"
else
  echo "  (skipped: no pwsh on this machine)"
fi

echo "every user-PATH write tells Windows about it"

# The bug this pins: writing HKCU\Environment is only half of setting the PATH.
# Without a WM_SETTINGCHANGE broadcast, Explorer keeps handing every process it
# starts the environment it cached at logon, so even a brand-new terminal
# cannot find ssm until the next sign-out. Counted rather than merely grepped,
# so a second write added later without its announcement fails here too.
for f in "$ROOT/install.ps1" "$PS"; do
  name="${f##*/}"
  # Any of the ways PowerShell can write that value, not just the one spelling
  # in use today: Set-/New-ItemProperty and a split-across-lines SetValue would
  # all leave a machine needing a sign-out.
  writes=$(grep -cE "(Registry\]::SetValue|Set-ItemProperty|New-ItemProperty).*(Environment|HKCU)" "$f")
  # Call sites only: not the definition, and not a comment naming the function
  # -- either would let a mention stand in for actually calling it.
  calls=$(grep -F 'Publish-SsmEnvironmentChange' "$f" |
    grep -v '^[[:space:]]*#' |
    grep -cv 'function Publish-SsmEnvironmentChange')

  if [[ $writes -ge 1 ]]; then pass; else fail "$name writes the user PATH"; fi
  if [[ $calls -ge $writes ]]; then pass; else
    fail "$name: $writes user-PATH write(s) but only $calls broadcast call(s)"
  fi
done

echo "both implementations write the same ssm.cmd"

# install.ps1 writes the shim and `ssm update` rewrites it, so the two copies
# have to agree -- and Test-SsmOwnLauncher compares content byte for byte, so
# a drift would make uninstall refuse to remove a shim ssm itself wrote.
shim_of() {
  awk '/^@echo off$/ { on = 1 } on { print } /^exit \/b 9009$/ { exit }' "$1"
}
assert_eq "$(shim_of "$ROOT/install.ps1")" "$(shim_of "$PS")" 'the ssm.cmd text matches'
if [[ -n "$(shim_of "$PS")" ]]; then pass; else fail 'the ssm.cmd text was found at all'; fi

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
