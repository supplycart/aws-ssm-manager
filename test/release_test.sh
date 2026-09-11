#!/bin/bash
# Unit tests for .github/scripts/release.sh, the helpers the deploy workflow
# uses to pick, stamp and find release versions. Run: bash test/release_test.sh

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../ssm.sh
source "$HERE/../ssm.sh"
# shellcheck source=../.github/scripts/release.sh
source "$HERE/../.github/scripts/release.sh"

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

echo "bump_version"

assert_eq "v1.0.0" "$(bump_version "" patch)" "first release"
assert_eq "v1.0.0" "$(bump_version "" major)" "first release ignores the bump"
assert_eq "v1.2.4" "$(bump_version v1.2.3 patch)" "patch"
assert_eq "v1.3.0" "$(bump_version v1.2.3 minor)" "minor resets patch"
assert_eq "v2.0.0" "$(bump_version v1.2.3 major)" "major resets minor and patch"
assert_eq "v1.10.0" "$(bump_version v1.9.9 minor)" "parts are numbers, not digits"
assert_eq "v0.0.1" "$(bump_version v0.0.0 patch)" "zero parts"

assert_status 1 "a tag without the v is refused" bump_version 1.2.3 patch
assert_contains "not a vX.Y.Z tag" "$LAST_OUTPUT" "bad tag message"
assert_status 1 "a pre-release tag is refused" bump_version v1.2.3-rc1 patch
assert_status 1 "leading zeros are refused" bump_version v1.08.0 patch
assert_status 1 "an unknown bump is refused" bump_version v1.2.3 huge
assert_contains "patch, minor or major" "$LAST_OUTPUT" "unknown bump message"
assert_status 1 "an unknown bump is refused on the first release too" bump_version "" huge

echo "bump_from_labels"

assert_eq "patch" "$(printf '' | bump_from_labels)" "no labels"
assert_eq "patch" "$(printf 'bug\nenhancement\n' | bump_from_labels)" "unrelated labels"
assert_eq "minor" "$(printf 'bug\nrelease:minor\n' | bump_from_labels)" "release:minor"
assert_eq "major" "$(printf 'release:major\nrelease:minor\n' | bump_from_labels)" "major listed before minor"
assert_eq "major" "$(printf 'release:minor\nrelease:major\n' | bump_from_labels)" "major listed after minor"
assert_eq "minor" "$(printf 'release:minor' | bump_from_labels)" "last label without a newline"

echo "stamp_version"

STAMP_FIXTURE=$(mktemp)
cp "$HERE/../ssm.sh" "$STAMP_FIXTURE"
chmod 755 "$STAMP_FIXTURE"

assert_status 0 "stamping the repository copy" stamp_version "$STAMP_FIXTURE" v1.2.3
assert_eq "v1.2.3" "$(script_version "$STAMP_FIXTURE")" "the stamp reads back"
assert_eq "ssm v1.2.3" "$(bash "$STAMP_FIXTURE" version)" "the stamped script reports it"
assert_eq "1" "$(diff "$HERE/../ssm.sh" "$STAMP_FIXTURE" | grep -c '^>')" "only one line changes"
assert_status 0 "the stamped file stays executable" test -x "$STAMP_FIXTURE"

assert_status 1 "an already stamped file is refused" stamp_version "$STAMP_FIXTURE" v1.2.4
assert_contains "found 0" "$LAST_OUTPUT" "missing line message"
assert_eq "v1.2.3" "$(script_version "$STAMP_FIXTURE")" "a refused stamp leaves the file alone"

printf 'SSM_VERSION="dev"\nSSM_VERSION="dev"\n' > "$STAMP_FIXTURE"
assert_status 1 "two version lines are refused" stamp_version "$STAMP_FIXTURE" v1.2.3
assert_contains "found 2" "$LAST_OUTPUT" "duplicate line message"

cp "$HERE/../ssm.sh" "$STAMP_FIXTURE"
assert_status 1 "a version that is not a tag is refused" stamp_version "$STAMP_FIXTURE" 1.2.3
assert_status 1 "a version with sed metacharacters is refused" stamp_version "$STAMP_FIXTURE" 'v1.2.3/&'
assert_eq "dev" "$(script_version "$STAMP_FIXTURE")" "refused versions leave the file alone"

rm -f "$STAMP_FIXTURE"

echo "latest_release_tag / existing_release_for"

REPO_FIXTURE=$(mktemp -d)
git_fixture() {
  git -C "$REPO_FIXTURE" -c user.name=test -c user.email=test@example.com \
    -c init.defaultBranch=master -c tag.gpgSign=false -c commit.gpgSign=false "$@"
}
in_fixture() { (cd "$REPO_FIXTURE" && "$@"); }

git_fixture init -q
assert_eq "" "$(in_fixture latest_release_tag)" "no tags in an empty repo"

git_fixture commit -q --allow-empty -m "Merged PR"
SOURCE_SHA=$(git_fixture rev-parse HEAD)
assert_eq "" "$(in_fixture latest_release_tag)" "no tags yet"
assert_eq "" "$(in_fixture existing_release_for "$SOURCE_SHA")" "an untagged commit has no release"

# Tags on the root commit: they sort, but have no parent to match.
git_fixture tag v1.9.0
git_fixture tag v1.10.0
git_fixture tag v2.0.0-rc1
git_fixture tag latest
assert_eq "v1.10.0" "$(in_fixture latest_release_tag)" "highest release tag, compared as versions"

git_fixture commit -q --allow-empty -m "Release v1.10.1"
git_fixture tag -a v1.10.1 -m v1.10.1
assert_eq "v1.10.1" "$(in_fixture latest_release_tag)" "an annotated release tag"
assert_eq "v1.10.1" "$(in_fixture existing_release_for "$SOURCE_SHA")" "finds the tag on top of the source commit"
assert_eq "" "$(in_fixture existing_release_for "$(git_fixture rev-parse HEAD)")" "the release commit itself has no release"
assert_status 0 "an unknown sha is not an error" in_fixture existing_release_for 0000000000000000000000000000000000000000

rm -rf "$REPO_FIXTURE"

echo ""
if [[ $FAILED -eq 0 ]]; then
  echo "ok — $PASSED assertions passed"
else
  echo "$FAILED of $((PASSED + FAILED)) assertions failed" >&2
  exit 1
fi
