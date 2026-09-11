# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- `bash install.sh` — install dependencies and symlink `ssm` to `/usr/local/bin/ssm` on macOS
- `ssm ssh / ssm pod / ssm db / ssm config / ssm update / ssm uninstall / ssm version / ssm help` — end-user CLI commands
- `bash -n install.sh && bash -n ssm.sh && bash -n .github/scripts/release.sh` — syntax check before committing
- `bash test/args_test.sh && bash test/release_test.sh` — unit tests for the argument and release
  helpers; run with the syntax check. CI runs the same pair as the required `test` check

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

`.github/workflows/deploy.yml` releases every push to `master` once the reusable `test.yml` passes:
1. Picks the next `vX.Y.Z` from the last tag and the merged PR's `release:minor` / `release:major` label.
2. Refuses to go on unless the tag ruleset is active.
3. Stamps `SSM_VERSION` into `ssm.sh` on a commit reachable only from the new tag, and pushes that tag.
4. Uploads `ssm.sh` and `install.sh` to the R2 bucket `supplycart-cdn` under `shells/aws-ssm-manager/vX.Y.Z/`, then `shells/aws-ssm-manager/`, then the legacy `shells/` (see below).
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

The CDN URLs are hard-coded in `install.sh` and in `cmd_update()` in `ssm.sh`. Do not change them
without a migration plan — already-installed clients pull updates from those exact paths.

The scripts moved from `shells/` to `shells/aws-ssm-manager/` after v1.1.0, to leave room for
other shells. Installs from before the move still update from `shells/ssm.sh`, so the deploy
keeps mirroring the latest `ssm.sh` and `install.sh` to `shells/`. Don't remove that mirror while
such installs may still exist. The deploy also copies every old `shells/vX.Y.Z/` release into
the new layout, skipping versions already copied.
