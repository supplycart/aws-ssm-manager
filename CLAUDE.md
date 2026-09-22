# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- `bash install.sh` — install dependencies and symlink `ssm` to `/usr/local/bin/ssm` on macOS
- `pwsh install.ps1` — the Windows 11 counterpart: winget dependencies,
  `%USERPROFILE%\.ssm`, a user-PATH entry and shortcuts
- `ssm` (no command) — opens a menu of the commands below, on both platforms, but only when
  stdin and stdout are a terminal and a picker is available; otherwise it prints usage and exits 1
- `ssm ssh / ssm pod / ssm db / ssm config / ssm update / ssm uninstall / ssm version / ssm help` — end-user CLI commands
- `bash -n install.sh && bash -n ssm.sh && bash -n .github/scripts/release.sh && bash -n .github/scripts/docs_upload.sh` — syntax check before committing
- `bash test/args_test.sh && bash test/release_test.sh && bash test/install_test.sh && bash test/docs_upload_test.sh && bash test/parity_test.sh`
  — unit tests for the argument, release, installer-version, docs-upload and cross-implementation
  parity helpers; run with the syntax check
- `pwsh -File test/ssm_test.ps1 && pwsh -File test/install_ps_test.ps1` — the PowerShell side, and
  a `Parser::ParseFile` pass over `ssm.ps1`/`install.ps1` as the `bash -n` equivalent
- CI runs all of the above inside the one required `test` job, on `ubuntu-latest` (pwsh is
  preinstalled there). Deliberately not a windows-latest job: a second job would be green but not
  required until someone edits the ruleset by hand
- `.github/workflows/install-windows.yml` runs the real `irm | iex` install on `windows-latest`
  under Windows PowerShell 5.1 and pwsh 7: on PRs touching the `.ps1` files (this commit, served
  from a local HTTP server) and after every release (from the CDN, called by `deploy.yml`). It is
  not part of the required check; add its two jobs to the ruleset to make it block
- `cd docs && pnpm install && pnpm dev` — docs site at `http://localhost:5173/shells/aws-ssm-manager/`;
  `pnpm format` before committing (CI runs `pnpm format:check` and `pnpm build`)

## Two implementations

`ssm.sh` (bash 3.2, macOS) and `ssm.ps1` (PowerShell 7, Windows 11) are two implementations of one
CLI. **Every command and every flag must exist in both.** `commands.manifest` is the source of
truth; `test/parity_test.sh` parses both shipped scripts and fails the required `test` check if
either disagrees. Neither implementation can satisfy it alone, which is the point.

Adding or removing a flag is a change in four places: `commands.manifest`, `ssm.sh`'s `parse_args`
call for that command, `ssm.ps1`'s `$SSM_COMMANDS` table, and the matching `docs/src/commands/`
page. The parity test also checks the docs, which is what stops them rotting silently.

`ssm.ps1` keeps its flag sets in one `$SSM_COMMANDS` table rather than inline per command, because
that is the region the parity test parses — and because a command then cannot accept a flag it
never declared. Every function carries a `# bash: <name> (ssm.sh:N)` anchor naming what it mirrors.

The usage text in `ssm.ps1` was generated from `ssm.sh`'s heredocs and must stay byte-identical
apart from a short list of platform tokens (`~/.ssm` ↔ `%USERPROFILE%\.ssm`, `brew install` ↔
`winget install`, `this Mac` ↔ `this PC`).

Where the two legitimately differ, the difference is recorded in `docs/src/reference/platforms.md`
and nowhere else:

- **Config parsing** — jq on macOS (with the startup check at `ssm.sh:11-15`); `ConvertFrom-Json`
  on Windows. There is **no jq dependency on Windows** and no startup check to mirror.
- **`ssm db` hostname** — `<identifier>.tunnel` via `/etc/hosts` on macOS, `127.0.0.1` on Windows.
  Matching macOS would mean a UAC prompt on every run, and an elevated write that is harder to
  undo than the macOS one, which already leaks the entry on a hard kill.
- **Dependencies** — Homebrew vs winget. `install.ps1` does **not** bootstrap winget the way
  `install.sh` bootstraps Homebrew; winget ships with Windows 11.
- **PATH** — a `/usr/local/bin/ssm` symlink vs `%USERPROFILE%\.ssm` on the user PATH plus an
  `ssm.cmd` shim. No symlink, so Developer Mode is never needed; nothing in `install.ps1` elevates.
  **Writing `HKCU:\Environment` is only half of it:** Explorer hands every process it starts the
  environment it cached at sign-in, so without a `WM_SETTINGCHANGE` broadcast even a brand-new
  terminal gets the old PATH — which is what shipped in v1.2.3 and made `ssm` unrecognised until
  the next sign-out. `Publish-SsmEnvironmentChange` in both `install.ps1` and `ssm.ps1` is that
  broadcast, and `test/parity_test.sh` counts PATH writes against broadcasts so a new write cannot
  be added without one. `[Environment]::SetEnvironmentVariable(…, 'User')` broadcasts by itself but
  writes the value back as `REG_SZ`, which is the `REG_EXPAND_SZ` downgrade the hand-rolled
  registry write exists to avoid — hence write by hand, broadcast by hand.
- **fzf** — required on macOS, optional on Windows, which falls back to a built-in console picker.
- **Pinned install** — a positional argument vs `$env:SSM_INSTALL_VERSION`, because `irm | iex`
  cannot take arguments.

PowerShell traps this port already hit, all of them caught by `test/ssm_test.ps1`:

- Variable names are **case-insensitive**, so `$account = ... $Account` silently clobbers the
  parameter. Locals that shadow a parameter get a different name.
- `-eq`, `-contains`, `switch` and hashtable keys are case-insensitive too, so the arg parser uses
  `-ceq`/`-cne`/`-clike`, `switch -CaseSensitive` and `StringComparer.Ordinal`. bash's `case` is
  case-sensitive, and `--ENV` must stay an unknown option.
- `ConvertTo-Json` defaults to `-Depth 2`; the config nests three deep, so every call passes
  `-Depth 100` or the db ports serialise as a type name.
- `$x = if (...) {...} else { @() }` unrolls the empty array to `$null`. Functions returning a
  possibly-empty array use `return , ([string[]]@(...))`.
- A function returns everything on the success stream, so the exit code travels as an exception
  (`Exit-Ssm`) and prompts go to `Write-Host`, never `Write-Output`.
- `$Host`, `$args`, `$input` and `$profile` are automatic variables; don't shadow them.

`install.ps1` targets **Windows PowerShell 5.1** as well as 7, because that is what the Start Menu
gives you and where the one-liner gets pasted. No ternaries, no `??`, no `$IsWindows`. Its source
guard is `if ($MyInvocation.InvocationName -eq '.') { return }`, and `$ErrorActionPreference` must
stay **below** it: a dot-sourced script sets preference variables in the caller's scope.

Never `Parser::ParseFile` a downloaded file in `install.ps1`: 5.1 reads a BOM-less file in the
ANSI code page, and the UTF-8 box/dash characters in `ssm.ps1` then decode into curly quotes that
end strings early. Read it as UTF-8 and use `ParseInput` — the v1.2.x installer failed every 5.1
install with "is not a valid script" this way.

Nothing in `install.ps1` may call `exit`. The documented entry point is `irm … | iex`, and `exit`
inside `Invoke-Expression` terminates the *caller's* session — the window closes instantly and
takes the error message with it, so a failed install is indistinguishable from a finished one.
`Write-Fail` throws; a throw stops the install, stays on screen, and still exits non-zero under
`pwsh -File`.

## Architecture

Shell-based tool engineers run locally to SSH into EC2 or tunnel to RDS via AWS SSM (no bastion
required). Config lives at `~/.ssm/config.json`. Key internals of `ssm.sh`:

- `select_menu()` wraps fzf for all interactive menus
- `load_config(account, field)` reads from `~/.ssm/config.json` via jq
- `get_db_port()` auto-assigns and persists local tunnel ports to config
- `print_tunnel_banner()` draws the `ssm db` endpoint box. The `C_*` color variables are set
  once at the top of the script and are empty unless stdout is a terminal, so piped output
  stays plain; box characters fall back to ASCII outside a UTF-8 locale
- All config writes follow the pattern: `updated=$(jq ... "$CONFIG_FILE") && echo "$updated" > "$CONFIG_FILE"`

Every interactive prompt also has a flag that answers it, so a fully flagged command runs without
stopping (`ssm ssh --env staging --app adam`). Two helpers carry this:

- `parse_args "<value-flags>" "<bool-flags>" "$@"` sets `ARG_<UPPER_SNAKE>` globals and rejects any
  flag the command didn't declare. Each `cmd_*` calls it first.
- `resolve_selection <wanted> <label> <context> <prompt> <match-fields> <auto> row...` replaces
  every `pick_*` body. Empty `<wanted>` means prompt; a value that matches nothing returns 1 after
  listing the candidates. It returns rather than exits, because callers run it inside `$( )` where
  an `exit` would only kill the subshell — hence the `|| exit 1` at every call site.

A flag added to a command must also be added to `ALL_ARG_FLAGS`. That list only drives the
clear-on-entry loop, so a flag missing from it still parses but keeps its value into the next
`parse_args` call — which the test suite checks for.

`ssm config` writes through small helpers that take `CONFIG_FILE` as it stands, so the test suite
points that global at a fixture and exercises them directly: `config_account_exists`,
`config_rename_account` (moves the whole object, so ports and region follow; never touches
`~/.aws`), `config_set_db_port` / `config_unset_db_port`, and `validate_port`. Ports are stored as
JSON numbers via `--argjson` — `find_free_port` scans the config with `[.. | numbers]`, so a port
written as a string would silently drop out of collision avoidance.

`ssm uninstall` always removes the `/usr/local/bin/ssm` symlink (only when it points at
`~/.ssm/ssm.sh`) and the script, then offers `~/.ssm` and each installed dependency on an
`fzf --multi` checklist (`select_multi`, which falls back to y/N prompts once fzf is gone). Its
paths (`SSM_DIR`, `SSM_SYMLINK`, `AWS_CLI_DIR`, `SSM_PLUGIN_DIR`, ...) are globals, so the tests
point them at a scratch directory and stub `brew` and `sudo`. It is the one command that runs
without jq — the startup check skips it — so keep jq calls out of it.

Secrets never come from a flag value: `read_secret_value` takes `SSM_AWS_SECRET_KEY` or one line
of stdin via `--secret-key -`.

The script targets **bash 3.2** (the macOS system bash): no associative arrays, no `${var^^}`, no
`mapfile`. The dispatch at the bottom is guarded by `[[ "${BASH_SOURCE[0]}" == "$0" ]]` so the
tests can source the script without running a command.

## Distribution

`ssm.sh` is served from the CDN (`https://cdn.supplycart.my/shells/aws-ssm-manager/ssm.sh`), downloaded to
`~/.ssm/ssm.sh` by `install.sh`, and made available as a system command via a symlink at
`/usr/local/bin/ssm`. `ssm update` re-downloads from the same URL.

`install.sh [vX.Y.Z]` installs that release from `shells/aws-ssm-manager/vX.Y.Z/ssm.sh`, or the
latest with no argument. `ssm_script_url` builds the URL and refuses anything but a plain tag; it
sits above a `(return 0 2>/dev/null)` source guard, so `test/install_test.sh` can source the file
without installing. `return` outside a function only succeeds in a sourced file, so the guard
lets both `bash install.sh` and the documented `bash <(curl …)` (a `/dev/fd` path) run through.
Validation and the CDN existence check run before the stdin and sudo checks, so a bad version
fails before anything is installed.

`docs/` is the VitePress docs site, laid out like `supplycart/wiki`: config split across
`docs/.vitepress/*.config.mts`, pages in `docs/src/`, sidebar in `docs/src/sidebar.mts`, and every
page needs `title`/`description` frontmatter plus a sidebar entry. `.github/workflows/docs.yml`
uploads the build into R2 under `shells/aws-ssm-manager/`, beside the release scripts, which
drives three constraints:

- `base` is `/shells/aws-ssm-manager/` and `cleanUrls` is off. R2 has no index document, so links
  name a page (`/commands/overview`), never a folder.
- `docs_upload_plan` in `.github/scripts/docs_upload.sh` (tested by `test/docs_upload_test.sh`)
  gives every file an explicit content type, since the CDN sends `nosniff`; add an extension there
  before the build starts emitting it. It lists pages after assets and refuses any build holding a
  `.sh`, `.ps1` or `.cmd` file or a `vX.Y.Z/` folder — those are release file names, and the docs
  share the prefix with them. `docs_content_type` deliberately has no entry for those three.
  Nothing in the docs deploy deletes.
- A redirect rule on the `supplycart.my` zone, managed in the Cloudflare dashboard, sends exactly
  `/shells/aws-ssm-manager` and `/shells/aws-ssm-manager/` to `index.html`. Never widen it to a
  prefix match: that would redirect `install.sh` and `ssm update`.

`VersionPicker.vue` on the install page reads releases from the GitHub API in the browser, so a
release needs no docs deploy. It has a macOS/Windows switch, defaulted from the visitor's platform
in `onMounted` (the component is server-rendered at build time, where `navigator` does not exist).
Its two CDN URLs must match `install.sh` and `install.ps1`.

`.github/workflows/deploy.yml` releases every push to `master` once the reusable `test.yml` passes:
1. Picks the next `vX.Y.Z` from the last tag and the merged PR's `release:minor` / `release:major` label.
2. Refuses to go on unless the tag ruleset is active.
3. Stamps the version into `ssm.sh` and `ssm.ps1` on a commit reachable only from the new tag, and pushes that tag.
4. Uploads `ssm.sh`, `install.sh`, `ssm.ps1` and `install.ps1` to the R2 bucket `supplycart-cdn`
   under `shells/aws-ssm-manager/vX.Y.Z/` and `shells/aws-ssm-manager/`. The `.ps1` files are
   uploaded with an explicit `text/plain` content type: without one R2 serves them as
   octet-stream, and `Invoke-RestMethod` then hands `iex` a `byte[]` it cannot execute.
   `ssm.cmd` is **not** a release artefact — `install.ps1` writes it locally, because cmd.exe is
   unforgiving about line endings and a BOM. Only the two bash files go to the legacy `shells/`
   (see below).

   The shim **locates** pwsh rather than naming it: on a fresh machine winget has just installed
   PowerShell 7 into a PATH the installing process cannot see, so a bare `pwsh` fails in the very
   terminal that ran the installer. Its text lives in both `install.ps1` and `$SSM_LAUNCHER_TEXT`
   in `ssm.ps1` (which rewrites it on `ssm update`), and `test/parity_test.sh` compares the two —
   they must stay byte-identical. Changing it means adding the previous text to
   `$SSM_LAUNCHER_LEGACY_TEXT`, because `Test-SsmOwnLauncher` decides whether uninstall may remove
   a shim by comparing content, and an unrecognised one is left on disk.
5. Publishes a GitHub release.

The shell logic lives in `.github/scripts/release.sh` (sourced, tested by `test/release_test.sh`).

- `ssm.sh` must keep exactly one `SSM_VERSION="dev"` line; `stamp_version` fails the release
  otherwise. `script_version` reads the stamp back, which is how `ssm update` reports old -> new.
- CI never pushes to `master`. The `master` ruleset requires a PR plus the `test` check,
  which is the job id in `test.yml`, so renaming that job blocks every PR.
- The tag ruleset blocks creating, moving or deleting `v*.*.*` tags for everyone outside the
  org's `bot` team. A tag can't be moved, so a rerun reuses the tag it finds on top of the
  commit (`existing_release_for`) instead of creating another.
- GitHub rejects the Actions app as a bypass actor, so GITHUB_TOKEN cannot create release tags.
  The release job checks out with the org secret `SUPPLYCART_BOT_TOKEN` and pushes the tag as
  `supplycart-bot`.
- Rulesets are managed in the GitHub UI (Settings → Rules → Rulesets), not in the repo.

The CDN URLs are hard-coded in `install.sh`, `install.ps1`, `cmd_update()` in `ssm.sh` and
`$SSM_CDN_BASE` in `ssm.ps1`, plus both entries in `VersionPicker.vue`. Do not change them without
a migration plan — already-installed clients pull updates from those exact paths.
`test/parity_test.sh` asserts each script names the base exactly once.

The scripts moved from `shells/` to `shells/aws-ssm-manager/` after v1.1.0, to leave room for
other shells. Installs from before the move still update from `shells/ssm.sh`, so the deploy
keeps mirroring the latest `ssm.sh` and `install.sh` to `shells/`. Don't remove that mirror while
such installs may still exist. That mirror is **frozen at `ssm.sh` and `install.sh`**: there has
never been a Windows release that could read from it, so the `.ps1` files never go there. The
deploy also copies every old `shells/vX.Y.Z/` release into the new layout, skipping versions
already copied; that backfill loop keeps its own two-file list.
