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
ssm config edit   --env <name> [--profile <p>] [--region <r>]
                  [--access-key <k>] [--secret-key -]
ssm config delete --env <name> [--yes] [--delete-profile]
```

`edit` applies every field flag you pass in one go. `delete` still asks for
confirmation unless you pass `--yes`, and keeps the AWS CLI profile unless you
pass `--delete-profile`.

| Action   | Description                                                                    |
| -------- | ------------------------------------------------------------------------------ |
| `view`   | Print `~/.ssm/config.json` and show masked AWS key IDs per account             |
| `add`    | Add a new account entry and optionally configure its AWS CLI credentials       |
| `edit`   | Edit `profile`, `region`, `aws-access-key`, or `aws-secret-key` for an account |
| `delete` | Remove an account and optionally delete the linked AWS CLI profile             |

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

- `profile` / `region` update `~/.ssm/config.json`
- `aws-access-key` updates `~/.aws/credentials` via `aws configure set`
- `aws-secret-key` updates `~/.aws/credentials` (input is hidden)

## delete

Removes the account from `~/.ssm/config.json` and optionally strips the AWS CLI
profile from `~/.aws/credentials` and `~/.aws/config`.
