#!/bin/bash
# Upload helpers for .github/workflows/docs.yml, which puts the built docs site
# into the CDN bucket next to the release scripts. Sourced, never run: the
# workflow sources it, and test/docs_upload_test.sh sources it to test it.

# docs_content_type <path>
# Prints the Content-Type to store a file with. The CDN sends
# X-Content-Type-Options: nosniff, so a script or stylesheet stored with a
# guessed or generic type would be refused by the browser.
docs_content_type() {
  case "$1" in
    *.html) echo "text/html; charset=utf-8" ;;
    *.js | *.mjs) echo "text/javascript; charset=utf-8" ;;
    *.css) echo "text/css; charset=utf-8" ;;
    *.json) echo "application/json; charset=utf-8" ;;
    *.svg) echo "image/svg+xml" ;;
    *.png) echo "image/png" ;;
    *.jpg | *.jpeg) echo "image/jpeg" ;;
    *.ico) echo "image/x-icon" ;;
    *.woff2) echo "font/woff2" ;;
    *.woff) echo "font/woff" ;;
    *.txt) echo "text/plain; charset=utf-8" ;;
    *.xml) echo "application/xml; charset=utf-8" ;;
    *) return 1 ;;
  esac
}

# docs_upload_plan <dist-dir>
# Prints one "<path><TAB><content-type>" line per file in the build, paths
# relative to <dist-dir>: every other file first and the HTML pages last, so no
# page goes live before the assets it loads.
#
# The site shares shells/aws-ssm-manager/ with the release scripts, so a build
# holding a .sh file or a vX.Y.Z/ folder is refused outright, as is a file with
# no known type. A refused build prints no plan at all.
docs_upload_plan() {
  local dist="$1" rel type failed=0 assets="" pages=""

  if [[ ! -d "$dist" ]]; then
    echo "Error: $dist is not a directory" >&2
    return 1
  fi

  while IFS= read -r rel; do
    case "$rel" in
      *.sh | v[0-9]*/*)
        echo "Error: $rel would overwrite a release file" >&2
        failed=1
        continue
        ;;
    esac
    if ! type=$(docs_content_type "$rel"); then
      echo "Error: no content type for $rel" >&2
      failed=1
      continue
    fi
    case "$rel" in
      *.html) pages+="$rel"$'\t'"$type"$'\n' ;;
      *) assets+="$rel"$'\t'"$type"$'\n' ;;
    esac
  done < <(cd "$dist" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)

  [[ $failed -eq 0 ]] || return 1
  if [[ -z "$assets$pages" ]]; then
    echo "Error: $dist has no files" >&2
    return 1
  fi
  printf '%s%s' "$assets" "$pages"
}
