#!/bin/bash
# Unit tests for install.sh's version handling. Sourcing install.sh defines
# ssm_script_url and stops before it installs anything, so this runs anywhere.
# Run: bash test/install_test.sh

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../install.sh
source "$HERE/../install.sh"

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

assert_status() {
  local expected="$1" what="$2"
  shift 2
  local out status
  out=$("$@" 2>&1)
  status=$?
  assert_eq "$expected" "$status" "$what (status)"
  LAST_OUTPUT="$out"
}

echo "sourcing install.sh"

assert_status 0 "the helper is defined" declare -F ssm_script_url
assert_eq "off" "$([[ $- == *e* ]] && echo on || echo off)" "sourcing stops before set -e"
assert_eq "" "$(declare -F error)" "sourcing stops before the install helpers"

echo "ssm_script_url"

CDN="https://cdn.supplycart.my/shells/aws-ssm-manager"
assert_eq "$CDN/ssm.sh" "$(ssm_script_url latest)" "latest is the unversioned copy"
assert_eq "$CDN/v1.2.3/ssm.sh" "$(ssm_script_url v1.2.3)" "a release tag"
assert_eq "$CDN/v1.10.0/ssm.sh" "$(ssm_script_url v1.10.0)" "parts are numbers, not digits"
assert_eq "$CDN/v0.0.1/ssm.sh" "$(ssm_script_url v0.0.1)" "zero parts"

for bad in "" "1.2.3" "v1.2" "v1.2.3.4" "v1.2.3-rc1" "v01.2.3" "V1.2.3" "LATEST" \
    "v1.2.3;rm -rf ~" "v1.2.3/../x" "../v1.2.3" " v1.2.3"; do
  assert_status 1 "'$bad' is refused" ssm_script_url "$bad"
  assert_contains "is not a version" "$LAST_OUTPUT" "'$bad' refusal message"
done

assert_eq "" "$(ssm_script_url nope 2>/dev/null)" "a refused version prints no URL"

echo ""
if [[ $FAILED -eq 0 ]]; then
  echo "ok — $PASSED assertions passed"
else
  echo "$FAILED of $((PASSED + FAILED)) assertions failed" >&2
  exit 1
fi
