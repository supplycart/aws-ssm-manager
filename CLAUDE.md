# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- `bash install.sh` — install dependencies and symlink `ssm` to `/usr/local/bin/ssm` on macOS
- `ssm ssh / ssm db / ssm config / ssm update / ssm help` — end-user CLI commands
- `bash -n install.sh && bash -n ssm.sh` — syntax check before committing

## Architecture

Shell-based tool engineers run locally to SSH into EC2 or tunnel to RDS via AWS SSM (no bastion
required). Config lives at `~/.ssm/config.json`. Key internals of `ssm.sh`:

- `select_menu()` wraps fzf for all interactive menus
- `load_config(account, field)` reads from `~/.ssm/config.json` via jq
- `get_db_port()` auto-assigns and persists local tunnel ports to config
- All config writes follow the pattern: `updated=$(jq ... "$CONFIG_FILE") && echo "$updated" > "$CONFIG_FILE"`

## Distribution

`ssm.sh` is served from the CDN (`https://cdn.supplycart.my/shells/ssm.sh`), downloaded to
`~/.ssm/ssm.sh` by `install.sh`, and made available as a system command via a symlink at
`/usr/local/bin/ssm`. `ssm update` re-downloads from the same URL.

`.github/workflows/deploy.yml` publishes on push to `master`: it syncs `install.sh` and `ssm.sh`
to the public R2 bucket `supplycart-cdn` under `shells/` using the S3-compatible API.

The CDN URLs are hard-coded in `install.sh` and in `cmd_update()` in `ssm.sh`. Do not change them
without a migration plan — already-installed clients pull updates from those exact paths.
