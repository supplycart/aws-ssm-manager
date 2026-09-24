---
title: Platform differences
description: Everything that differs between ssm on macOS and ssm on Windows 11.
---

# Platform differences

ssm is one CLI with two implementations: `ssm.sh` for macOS and `ssm.ps1` for
Windows 11. **Every command and every flag exists in both**, and CI fails if
they drift apart, so nothing on the [commands](/commands/overview) pages is
platform-specific.

What genuinely differs is below. This page is the whole list.

|                    | macOS                             | Windows 11                               |
| ------------------ | --------------------------------- | ---------------------------------------- |
| Install            | `bash <(curl …install.sh)`        | `irm …install.ps1 \| iex`                |
| Pin a version      | an argument after the command     | `$env:SSM_INSTALL_VERSION`               |
| Dependencies       | Homebrew                          | winget                                   |
| JSON parsing       | `jq`                              | built into PowerShell                    |
| Fuzzy menus        | `fzf`, required                   | `fzf` if present, else a built-in picker |
| Where it lives     | `~/.ssm/ssm.sh`                   | `%USERPROFILE%\.ssm\ssm.ps1`             |
| How `ssm` resolves | a symlink at `/usr/local/bin/ssm` | `.ssm\bin\ssm.cmd` on your user PATH     |
| Shortcuts          | none                              | Start Menu and Desktop                   |
| `ssm db` hostname  | `<identifier>.tunnel`             | `127.0.0.1`                              |
| Elevation          | `sudo`, once, at install          | none for ssm itself                      |

Your `config.json` has the same shape and the same location on both — `$HOME`
is `%USERPROFILE%` — so it is portable between a Mac and a Windows box, saved
database ports included.

## Why `ssm db` differs

On macOS, `ssm db` adds `127.0.0.1  <identifier>.tunnel` to `/etc/hosts` so you
can point a database client at a name rather than an address, and removes it
again when the tunnel closes.

Windows keeps its hosts file in `C:\Windows\System32\drivers\etc\hosts`, which
is writable only by an administrator. Matching macOS would mean a UAC consent
dialog on **every** `ssm db`, and an elevated write is harder to undo reliably
than the macOS one — which already leaves the entry behind if the process is
killed outright.

So Windows skips the alias. The tunnel banner shows `127.0.0.1` and the port,
and that is what you give your client. If you want the hostname anyway, add it
yourself once, from an elevated prompt:

```powershell
Add-Content $env:SystemRoot\System32\drivers\etc\hosts "127.0.0.1  my-db.tunnel"
```

## Why there is no `jq` on Windows

PowerShell has `ConvertFrom-Json` built in, so shelling out to `jq` for it
would be a dependency bought for nothing. One fewer thing to install, and one
fewer thing that can be missing.

The consequence worth knowing: ports in `config.json` are stored as JSON
numbers on both platforms, and a port written as a string — by hand-editing the
file — drops out of collision detection on both.

## Why `fzf` is optional on Windows

On macOS, a menu without `fzf` is an error. On Windows, ssm falls back to a
built-in console picker with the same arrow-keys-and-type-to-filter behaviour,
so a failed `fzf` install never blocks anyone. Install it for the nicer one:

```powershell
winget install junegunn.fzf
```

Either way, every menu has a flag that replaces it, so a fully flagged command
never opens one at all.
