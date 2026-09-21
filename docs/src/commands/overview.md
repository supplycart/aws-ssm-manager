---
title: Commands
description: The ssm commands, and the flags that answer each menu.
---

# Commands

```sh
ssm            # Ask what to do, and run it
ssm ssh        # Shell into an EC2 instance or an ECS/Fargate container
ssm pod        # Shell into an EKS pod
ssm db         # Open an RDS tunnel
ssm config     # Manage account profiles and AWS credentials
ssm update     # Update ssm to the latest version
ssm uninstall  # Remove ssm, and optionally its config and dependencies
ssm version    # Print the installed version
ssm help       # Show usage and config info
```

The command set and the flags are identical on macOS and Windows; see
[platform differences](/reference/platforms) for the short list of what is not.

## Starting from a menu

`ssm` on its own asks what you want to do and then runs it, so there is nothing
to memorise. It is what the Windows Start Menu shortcut launches.

The menu only opens when there is a terminal to draw it on. Piped, redirected,
or in a CI job, bare `ssm` prints usage and exits 1 as it always has — so
nothing scripted against it changes.

## Skipping the menus

Every prompt has a flag that answers it. Supply the flags you know and the rest
still come up as menus, so `ssm ssh` on its own behaves exactly as it always
has:

```sh
ssm ssh                                   # fully interactive
ssm ssh --env staging                     # skips the account menu
ssm ssh --env staging --app adam          # no prompts at all if the app has one instance
ssm ssh --env staging --app adam --container php-fpm
ssm db  --env staging --app adam --db sc-staging-adam-rds
ssm pod --env staging -n default --pod api-7d9f
```

| Command  | Flags                                                                                                     |
| -------- | --------------------------------------------------------------------------------------------------------- |
| all      | `--env\|-e <name>` (alias `--account`), `--help\|-h`                                                      |
| `ssh`    | `--app <name>`, `--type ec2\|ecs`, `--instance <id\|Name>`, `--container <name>`, `--task <id>`, `--host` |
| `db`     | `--app <name>`, `--db <identifier>`, `--instance <id\|Name>`                                              |
| `pod`    | `--cluster <name>`, `--namespace\|-n <ns>`, `--pod <name>`, `--container\|-c <name>`                      |
| `config` | see [ssm config](/commands/config)                                                                        |

`--flag value` and `--flag=value` both work. `ssm <command> --help` prints that
command's flags.

A value that doesn't exist is an error listing the valid ones, never a
re-prompt, so a fully flagged command can't stall waiting for input:

```txt
$ ssm ssh --env staging --app adm
Error: no app 'adm' in account staging.
Available:
  adam
  eva
  hub
```

Instances match on either their id or their `Name` tag, so
`--instance i-0abc123` and `--instance web-01` both work. If `--container`
matches several running tasks, `ssm` lists them and asks you to add
`--task <id>`.
