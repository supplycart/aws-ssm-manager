#!/bin/bash
# Release helpers for .github/workflows/deploy.yml. Sourced, never run: the
# workflow sources it for each step, and test/release_test.sh sources it to
# test the functions.

# A release tag. No leading zeros, so arithmetic never reads a part as octal.
SEMVER_TAG_RE='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

# bump_version <last-tag|""> <patch|minor|major>
# Prints the next tag. With no previous tag the first release is v1.0.0.
bump_version() {
  local last="$1" part="$2"

  case "$part" in
    patch|minor|major) ;;
    *) echo "Error: bump must be patch, minor or major, got '$part'" >&2; return 1 ;;
  esac

  if [[ -z "$last" ]]; then
    echo "v1.0.0"
    return 0
  fi

  if [[ ! "$last" =~ $SEMVER_TAG_RE ]]; then
    echo "Error: '$last' is not a vX.Y.Z tag" >&2
    return 1
  fi

  local major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"
  case "$part" in
    major) echo "v$((major + 1)).0.0" ;;
    minor) echo "v$major.$((minor + 1)).0" ;;
    patch) echo "v$major.$minor.$((patch + 1))" ;;
  esac
}

# Reads PR label names, one per line, on stdin and prints the bump they ask
# for: release:major wins over release:minor, and no label means patch.
bump_from_labels() {
  local label part="patch"
  while IFS= read -r label || [[ -n "$label" ]]; do
    if [[ "$label" == "release:major" ]]; then
      part="major"
    elif [[ "$label" == "release:minor" && "$part" == "patch" ]]; then
      part="minor"
    fi
  done
  echo "$part"
}

# stamp_version <file> <tag>
# Rewrites the version line: SSM_VERSION="dev" in a .sh, $SSM_VERSION = 'dev'
# in a .ps1. Fails unless there is exactly one such line, so a renamed variable
# -- or a bash line pasted into the PowerShell script -- stops the release
# instead of shipping "dev".
stamp_version() {
  local file="$1" version="$2" count dev new

  if [[ ! "$version" =~ $SEMVER_TAG_RE ]]; then
    echo "Error: '$version' is not a vX.Y.Z tag" >&2
    return 1
  fi

  case "$file" in
    *.ps1) dev="\$SSM_VERSION = 'dev'"; new="\$SSM_VERSION = '$version'" ;;
    *)     dev="SSM_VERSION=\"dev\"";   new="SSM_VERSION=\"$version\"" ;;
  esac

  # -Fx is a fixed-string whole-line match, so the $ and the quotes in the
  # PowerShell form carry no regex meaning.
  count=$(grep -cFx -- "$dev" "$file" || true)
  if [[ "$count" != "1" ]]; then
    echo "Error: expected one $dev line in $file, found ${count:-0}" >&2
    return 1
  fi

  # awk compares whole lines as data, so neither the pattern nor the tag is a
  # program. The tag is semver-checked above, and neither string can contain a
  # backslash, which is the one thing awk -v would still interpret.
  # Written back through the same inode so the file keeps its mode.
  local tmp="$file.stamp.$$"
  awk -v dev="$dev" -v new="$new" '$0 == dev { $0 = new } { print }' "$file" > "$tmp" &&
    cat "$tmp" > "$file" &&
    rm -f "$tmp"
}

# Prints the highest vX.Y.Z tag in the local clone, or nothing.
latest_release_tag() {
  git tag -l 'v*.*.*' --sort=-v:refname | grep -E "$SEMVER_TAG_RE" | sed -n 1p || true
}

# existing_release_for <sha>
# Prints the tag whose release commit sits directly on top of <sha>, or
# nothing. This is how a re-run finds the tag an earlier attempt pushed.
existing_release_for() {
  local sha="$1" tag parent
  while IFS= read -r tag; do
    parent=$(git rev-parse -q --verify "$tag^" 2>/dev/null) || continue
    if [[ "$parent" == "$sha" ]]; then
      echo "$tag"
      return 0
    fi
  done < <(git tag -l 'v*.*.*')
  return 0
}
