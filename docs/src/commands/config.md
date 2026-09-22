---
title: ssm config
description: View, add, edit and delete the AWS accounts ssm uses.
---

# ssm config

Run `ssm config` for the menu, or name the action directly:

```sh
ssm config view   [--env <name>]
ssm config add    --env <name> [--profile <p>] [--region <r>]
                  [--access-key <k>] [--secret-key -] [--skip-credentials]
                  [--force]
ssm config edit   --env <name> [--name <new>] [--profile <p>] [--region <r>]
                  [--access-key <k>] [--secret-key -]
                  [--db <identifier> --port <n>]
ssm config delete --env <name> [--db <identifier>] [--yes] [--delete-profile]
```

`edit` applies every field flag you pass in one go. `delete` still asks for
confirmation unless you pass `--yes`, and keeps the AWS CLI profile unless you
pass `--delete-profile`.

Adding over an account that already exists is refused, because it would take
that account's saved database ports with it. Pass `--force` to replace it
anyway.

| Action   | Description                                                                  |
| -------- | ---------------------------------------------------------------------------- |
| `view`   | Print `~/.ssm/config.json` and show masked AWS key IDs per account           |
| `add`    | Add a new account entry and optionally configure its AWS CLI credentials     |
| `edit`   | Rename an account, or edit `profile`, `region`, its keys, or a database port |
| `delete` | Remove an account and optionally delete the linked AWS CLI profile           |

## Secrets

**Secrets are never taken as a flag value**: that would record them in your
shell history and expose them in `ps`. Pass them one of these two ways instead:

```sh
SSM_AWS_SECRET_KEY="$SECRET" ssm config add --env staging --profile sc-staging \
  --region ap-southeast-5 --access-key AKIA...

echo "$SECRET" | ssm config edit --env staging --secret-key -
```

## add

Prompts for:

- Account name (key in `~/.ssm/config.json`)
- AWS CLI profile name
- AWS region
- Access Key ID and Secret Access Key (optional, and skippable)

## edit

- `--name` renames the account, moving its profile, region and saved database
  ports with it. Your `~/.aws` files are never touched: the AWS CLI profile is
  a field on the account, not its name.
- `profile` / `region` update `~/.ssm/config.json`
- `aws-access-key` updates `~/.aws/credentials` via `aws configure set`
- `aws-secret-key` updates `~/.aws/credentials` (input is hidden)
- `--db` and `--port` go together and set the local port for one database.
  `ssm db` assigns a free port on first use and remembers it; this is how you
  pin a different one. A port already used by another account is a warning,
  not an error.

```sh
ssm config edit --env staging --name stg
ssm config edit --env staging --db sc-staging-adam-rds --port 15433
```

## delete

Removes the account from `~/.ssm/config.json` and optionally strips the AWS CLI
profile from `~/.aws/credentials` and `~/.aws/config`.

With `--db`, only that one port assignment goes and the account stays:

```sh
ssm config delete --env staging --db sc-staging-adam-rds
```
