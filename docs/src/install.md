---
title: Install
description: Install ssm on macOS or Windows 11, either the latest version or a specific release.
---

# Install

ssm runs on **macOS**, on Apple Silicon and Intel, and on **Windows 11**.

Pick your platform and a version, then run the command:

<VersionPicker />

## macOS

The installer asks for your password once, for the AWS installers and the
`/usr/local/bin/ssm` link.

::: warning Don't pipe the installer into bash
Run it exactly as shown. `curl … | bash` takes over the terminal's input, so the
password prompt can't work and the installer stops.
:::

What gets installed:

- Homebrew, if it isn't there already
- `fzf`, `jq` and `kubectl` from Homebrew
- AWS CLI v2 and the AWS Session Manager plugin
- `~/.ssm/ssm.sh`, linked as `/usr/local/bin/ssm`, plus an empty
  `~/.ssm/config.json`

## Windows 11

The Windows installer needs no administrator rights of its own — everything it
writes is per-user. Windows will ask for permission once per AWS installer,
because those are machine-wide packages.

::: tip Piping is fine here
Unlike the macOS installer, this one never prompts for a password, so
`irm … | iex` is the documented way to run it.
:::

What gets installed, via `winget`:

- PowerShell 7, if it isn't there already
- AWS CLI v2, the AWS Session Manager plugin and `kubectl`
- `fzf`, which is optional — ssm falls back to a built-in picker if it is
  missing or fails to install
- `%USERPROFILE%\.ssm\ssm.ps1`, the `%USERPROFILE%\.ssm\bin\ssm.cmd` shim, and
  an empty `config.json`

It then adds `%USERPROFILE%\.ssm\bin` to your **user** PATH and creates an
`ssm` shortcut in the Start Menu and on the Desktop.

There is no `jq` on Windows: PowerShell reads JSON itself.

::: warning Open a new terminal
Terminals that were already open won't see the new PATH entry. The Start Menu
shortcut works straight away.
:::

### Running it

Double-click the **ssm** shortcut and it asks what you want to do. Or type it
at any CMD, PowerShell or Windows Terminal prompt:

```powershell
ssm                 # pick what to do from a menu
ssm config add      # add your first AWS account
ssm ssh --env staging --app adam
```

`ssm.cmd` is what makes the bare word `ssm` work: `.ps1` is not in `PATHEXT`,
and `cmd.exe` cannot run a PowerShell script directly. It lives in its own
`bin` folder so that PowerShell never finds `ssm.ps1` first — see below.

### If `ssm` complains about `#requires` and PowerShell 7.2

> `The script 'ssm.ps1' cannot be run because it contained a "#requires"
statement for Windows PowerShell 7.2.`

Installs up to **v1.2.5** put `%USERPROFILE%\.ssm` itself on the PATH. In that
folder PowerShell picks `ssm.ps1` over `ssm.cmd`, so Windows PowerShell 5.1 ran
the script directly instead of handing it to PowerShell 7.

Run the installer again, from any PowerShell window. It moves the shim into
`bin` and fixes the PATH, and `ssm` works in that same window straight away:

```powershell
irm https://cdn.supplycart.my/shells/aws-ssm-manager/install.ps1 | iex
```

Running any `ssm` command from PowerShell 7 or `cmd` makes the same move by
itself, once you are on a release with this fix.

### If `ssm` is not recognized

> `The term 'ssm' is not recognized as the name of a cmdlet, function, script
file, or operable program.`

Installers up to **v1.2.3** added the PATH entry without telling Windows about
it, so new terminals kept the environment Explorer had cached at sign-in.

Either of these fixes it:

- **`ssm update`**, from the Start Menu shortcut. The shortcut works even when
  the name does not, because it points straight at the script.
- **Run the installer again**, which repairs the PATH entry and re-announces
  it:

  ```powershell
  irm https://cdn.supplycart.my/shells/aws-ssm-manager/install.ps1 | iex
  ```

  Note that this installs the **latest** release. If you are pinned to an older
  one and want to stay there, set `$env:SSM_INSTALL_VERSION` to your tag first.

Then open a new terminal. Signing out and back in also works, and always did.

If it still does not resolve, check what actually got installed:

```powershell
Test-Path "$env:USERPROFILE\.ssm\bin\ssm.cmd"
(Get-Item 'HKCU:\Environment').GetValue('Path', '', 'DoNotExpandEnvironmentNames')
```

`False` means the install did not finish — run it again and read the output.
The installer no longer closes the window when it fails.

## Versions and updates

Without a version, the installer installs the latest release. With one it
installs that release, and checks it exists before installing anything.

```sh
ssm version   # the installed version, e.g. ssm v1.1.0
ssm update    # move to the latest release
```

A pinned install stays on its release until you run `ssm update`.

On Windows, a version is pinned through an environment variable rather than an
argument, because `irm … | iex` has no way to pass one:

```powershell
$env:SSM_INSTALL_VERSION = 'v1.1.0'; irm https://cdn.supplycart.my/shells/aws-ssm-manager/install.ps1 | iex
```

Releases from before Windows support have no `ssm.ps1`, so pinning to one of
them on Windows fails before it installs anything.

## Next steps

- [Configure](/configure) your AWS accounts
- [Platform differences](/reference/platforms) between macOS and Windows
- [Uninstall](/commands/uninstall) ssm when you no longer need it
