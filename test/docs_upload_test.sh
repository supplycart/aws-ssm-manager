#!/bin/bash
# Unit tests for .github/scripts/docs_upload.sh, which decides what the docs
# deploy uploads next to the release scripts. Run: bash test/docs_upload_test.sh

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../.github/scripts/docs_upload.sh
source "$HERE/../.github/scripts/docs_upload.sh"

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

echo "docs_content_type"

assert_eq "text/html; charset=utf-8" "$(docs_content_type commands/ssh.html)" "a page"
assert_eq "text/javascript; charset=utf-8" "$(docs_content_type assets/app.B1x.js)" "a script"
assert_eq "text/javascript; charset=utf-8" \
  "$(docs_content_type assets/chunks/@localSearchIndexroot.D3y.js)" "the search index chunk"
assert_eq "text/css; charset=utf-8" "$(docs_content_type assets/style.C2z.css)" "a stylesheet"
assert_eq "font/woff2" "$(docs_content_type assets/inter-roman-latin.Di8.woff2)" "a font"
assert_eq "image/png" "$(docs_content_type supplycart.png)" "an image"
assert_eq "image/svg+xml" "$(docs_content_type logo.svg)" "an svg"
assert_status 1 "a source map has no type" docs_content_type assets/app.B1x.js.map
assert_status 1 "a file without an extension has no type" docs_content_type LICENSE

echo "docs_upload_plan"

TAB=$'\t'
DIST=$(mktemp -d)
mkdir -p "$DIST/assets/chunks" "$DIST/commands"
touch "$DIST/index.html" "$DIST/install.html" "$DIST/commands/ssh.html" \
  "$DIST/assets/app.B1x.js" "$DIST/assets/style.C2z.css" \
  "$DIST/assets/chunks/_localSearchIndexroot.D3y.js" "$DIST/supplycart.png"

EXPECTED="assets/app.B1x.js${TAB}text/javascript; charset=utf-8
assets/chunks/_localSearchIndexroot.D3y.js${TAB}text/javascript; charset=utf-8
assets/style.C2z.css${TAB}text/css; charset=utf-8
supplycart.png${TAB}image/png
commands/ssh.html${TAB}text/html; charset=utf-8
index.html${TAB}text/html; charset=utf-8
install.html${TAB}text/html; charset=utf-8"
assert_eq "$EXPECTED" "$(docs_upload_plan "$DIST")" "assets first, then pages, each sorted"

touch "$DIST/install.sh"
assert_status 1 "a build containing install.sh is refused" docs_upload_plan "$DIST"
assert_contains "install.sh would overwrite a release file" "$LAST_OUTPUT" "install.sh message"
assert_eq "" "$(docs_upload_plan "$DIST" 2>/dev/null)" "a refused build prints no plan"
rm "$DIST/install.sh"

touch "$DIST/ssm.sh"
assert_status 1 "a build containing ssm.sh is refused" docs_upload_plan "$DIST"
rm "$DIST/ssm.sh"

mkdir "$DIST/v1.2.3"
touch "$DIST/v1.2.3/index.html"
assert_status 1 "a version folder is refused" docs_upload_plan "$DIST"
assert_contains "v1.2.3/index.html would overwrite a release file" "$LAST_OUTPUT" "version folder message"
rm -rf "$DIST/v1.2.3"

touch "$DIST/assets/app.B1x.js.map"
assert_status 1 "a file with no known type is refused" docs_upload_plan "$DIST"
assert_contains "no content type for assets/app.B1x.js.map" "$LAST_OUTPUT" "unknown type message"
rm "$DIST/assets/app.B1x.js.map"

# A literal @ in the path is a 403 from the CDN, so such a build never ships:
# the file would upload and then be unreachable by the name the page asks for.
touch "$DIST/assets/chunks/@localSearchIndexroot.D3y.js"
assert_status 1 "an @ in a filename is refused" docs_upload_plan "$DIST"
assert_contains "the CDN will not serve by that name" "$LAST_OUTPUT" "unsafe character message"
rm "$DIST/assets/chunks/@localSearchIndexroot.D3y.js"

touch "$DIST/assets/a b.js"
assert_status 1 "a space in a filename is refused" docs_upload_plan "$DIST"
rm "$DIST/assets/a b.js"

assert_status 0 "the cleaned-up build is accepted again" docs_upload_plan "$DIST"
assert_status 1 "a missing directory is refused" docs_upload_plan "$DIST/missing"

EMPTY=$(mktemp -d)
assert_status 1 "an empty build is refused" docs_upload_plan "$EMPTY"
assert_contains "has no files" "$LAST_OUTPUT" "empty build message"

rm -rf "$DIST" "$EMPTY"

echo ""
if [[ $FAILED -eq 0 ]]; then
  echo "ok — $PASSED assertions passed"
else
  echo "$FAILED of $((PASSED + FAILED)) assertions failed" >&2
  exit 1
fi
