---
title: Install
description: Install ssm on macOS, either the latest version or a specific release.
---

# Install

ssm runs on **macOS only**, on Apple Silicon and Intel. The installer asks for
your password once, for the AWS installers and the `/usr/local/bin/ssm` link.

## Install ssm

Pick a version, then run the command in Terminal:

<VersionPicker />

::: warning Don't pipe the installer into bash
Run it exactly as shown. `curl … | bash` takes over the terminal's input, so the
password prompt can't work and the installer stops.
:::

## What gets installed

- Homebrew, if it isn't there already
- `fzf`, `jq` and `kubectl` from Homebrew
- AWS CLI v2 and the AWS Session Manager plugin
- `~/.ssm/ssm.sh`, linked as `/usr/local/bin/ssm`, plus an empty
  `~/.ssm/config.json`

Anything already installed is left as it is, so running the installer again is
safe. The `ssm` command works in any new shell straight away.

## Versions and updates

Without a version, the installer installs the latest release. With a tag after
the command it installs that release, and checks the tag exists before it
installs anything.

```sh
ssm version   # the installed version, e.g. ssm v1.1.0
ssm update    # move to the latest release
```

A pinned install stays on its release until you run `ssm update`.

## Next steps

- [Configure](/configure) your AWS accounts
- [Uninstall](/commands/uninstall) ssm when you no longer need it
