---
title: ssm uninstall
description: Remove ssm, and optionally its config and dependencies.
---

# ssm uninstall

```sh
ssm uninstall [--yes] [--purge] [--with-deps]
```

After a confirmation, removes the `ssm` command itself, then opens a checklist
of what else is on the machine. Tab marks an item, Enter confirms.

Only items that are installed are listed, and nothing is removed unless you
mark it: pressing Enter straight away keeps everything. ssm cannot tell whether
the installer added a dependency or found it already there, and other tools may
rely on them. `~/.aws` is never touched, and neither is Homebrew or winget
itself.

### macOS

Always removed: the `/usr/local/bin/ssm` symlink and `~/.ssm/ssm.sh`. A
`/usr/local/bin/ssm` that points anywhere else is left alone.

| Item                                              | Removed with                                                  |
| ------------------------------------------------- | ------------------------------------------------------------- |
| `~/.ssm`: config, remembered DB ports, kubeconfig | `rm -rf ~/.ssm`                                               |
| `fzf`, `jq`, `kubectl`                            | `brew uninstall`                                              |
| AWS CLI v2                                        | `/usr/local/aws-cli` and its links in `/usr/local/bin` (sudo) |
| Session Manager plugin                            | `/usr/local/sessionmanagerplugin` and its link (sudo)         |

### Windows

Always removed: `%USERPROFILE%\.ssm\ssm.ps1`, the `ssm.cmd` shim, the
`%USERPROFILE%\.ssm` entry in your user PATH, and the Start Menu and Desktop
shortcuts. An `ssm.cmd` that is not the one ssm installed is left alone.

| Item                                                          | Removed with               |
| ------------------------------------------------------------- | -------------------------- |
| `%USERPROFILE%\.ssm`: config, remembered DB ports, kubeconfig | deleted                    |
| `fzf`, `kubectl`                                              | `winget uninstall`         |
| AWS CLI v2                                                    | `winget uninstall` (admin) |
| Session Manager plugin                                        | `winget uninstall` (admin) |

Nothing here self-elevates. An item that needs an administrator is reported
with the exact command to run, rather than springing a UAC prompt part-way
through an uninstall. There is no `jq` row: Windows never installs one.

## Flags

`--yes` skips the confirmation and removes only the command. Add `--purge` for
`~/.ssm` and `--with-deps` for the dependencies.
