---
title: ssm uninstall
description: Remove ssm, and optionally its config and dependencies.
---

# ssm uninstall

```sh
ssm uninstall [--yes] [--purge] [--with-deps]
```

After a confirmation, removes the `ssm` command: the `/usr/local/bin/ssm`
symlink and `~/.ssm/ssm.sh`. A `/usr/local/bin/ssm` that points anywhere else
is left alone.

It then opens a checklist of what else is on the machine. Tab marks an item,
Enter confirms:

| Item                                              | Removed with                                                  |
| ------------------------------------------------- | ------------------------------------------------------------- |
| `~/.ssm`: config, remembered DB ports, kubeconfig | `rm -rf ~/.ssm`                                               |
| `fzf`, `jq`, `kubectl`                            | `brew uninstall`                                              |
| AWS CLI v2                                        | `/usr/local/aws-cli` and its links in `/usr/local/bin` (sudo) |
| Session Manager plugin                            | `/usr/local/sessionmanagerplugin` and its link (sudo)         |

Only items that are installed are listed, and nothing is removed unless you
mark it: pressing Enter straight away keeps everything. ssm cannot tell whether
the installer added a dependency or found it already there, and other tools may
rely on them. `~/.aws` and Homebrew itself are never touched.

## Flags

`--yes` skips the confirmation and removes only the command. Add `--purge` for
`~/.ssm` and `--with-deps` for the dependencies.
