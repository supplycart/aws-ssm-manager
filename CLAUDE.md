# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- `bash install.sh` — install dependencies and symlink `ssm` to `/usr/local/bin/ssm` on macOS
- `ssm ssh / ssm pod / ssm db / ssm config / ssm update / ssm help` — end-user CLI commands
- `bash -n install.sh && bash -n ssm.sh` — syntax check before committing
- `bash test/args_test.sh` — unit tests for the argument helpers; run with the syntax check

## Architecture

Shell-based tool engineers run locally to SSH into EC2 or tunnel to RDS via AWS SSM (no bastion
required). Config lives at `~/.ssm/config.json`. Key internals of `ssm.sh`:

- `select_menu()` wraps fzf for all interactive menus
- `load_config(account, field)` reads from `~/.ssm/config.json` via jq
- `get_db_port()` auto-assigns and persists local tunnel ports to config
- All config writes follow the pattern: `updated=$(jq ... "$CONFIG_FILE") && echo "$updated" > "$CONFIG_FILE"`

Every interactive prompt also has a flag that answers it, so a fully flagged command runs without
stopping (`ssm ssh --env staging --app adam`). Two helpers carry this:

- `parse_args "<value-flags>" "<bool-flags>" "$@"` sets `ARG_<UPPER_SNAKE>` globals and rejects any
  flag the command didn't declare. Each `cmd_*` calls it first.
- `resolve_selection <wanted> <label> <context> <prompt> <match-fields> <auto> row...` replaces
  every `pick_*` body. Empty `<wanted>` means prompt; a value that matches nothing returns 1 after
  listing the candidates. It returns rather than exits, because callers run it inside `$( )` where
  an `exit` would only kill the subshell — hence the `|| exit 1` at every call site.

Secrets never come from a flag value: `read_secret_value` takes `SSM_AWS_SECRET_KEY` or one line
of stdin via `--secret-key -`.

The script targets **bash 3.2** (the macOS system bash): no associative arrays, no `${var^^}`, no
`mapfile`. The dispatch at the bottom is guarded by `[[ "${BASH_SOURCE[0]}" == "$0" ]]` so the
tests can source the script without running a command.

## Distribution

`ssm.sh` is served from the CDN (`https://cdn.supplycart.my/shells/ssm.sh`), downloaded to
`~/.ssm/ssm.sh` by `install.sh`, and made available as a system command via a symlink at
`/usr/local/bin/ssm`. `ssm update` re-downloads from the same URL.

`.github/workflows/deploy.yml` publishes on push to `master`: it syncs `install.sh` and `ssm.sh`
to the public R2 bucket `supplycart-cdn` under `shells/` using the S3-compatible API.

The CDN URLs are hard-coded in `install.sh` and in `cmd_update()` in `ssm.sh`. Do not change them
without a migration plan — already-installed clients pull updates from those exact paths.
