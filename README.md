# SSM Command

An interactive CLI tool for connecting to AWS EC2 instances and RDS databases via AWS Systems Manager (SSM), without needing a bastion host or open SSH ports.

## Features

- Interactive environment, application, and instance selection using arrow keys
- SSH into any EC2 instance via SSM
- Open RDS tunnels via SSM port forwarding (supports PostgreSQL, MySQL, and any engine)
- Manage AWS account profiles and CLI credentials via `ssm config`
- Auto-discovers apps and instances from EC2/RDS `App` tags
- Stable local ports per database — configure your DB client once
- Temporary `/etc/hosts` alias while the DB tunnel is active (e.g. `sc-staging-adam-rds.tunnel`)

## Prerequisites

### 1. Install

```bash
bash <(curl -fsSL https://cdn.supplycart.my/shells/install.sh)
```

This installs `awscli`, `fzf`, `jq`, the AWS Session Manager plugin, and creates a symlink at `/usr/local/bin/ssm` pointing to `~/.ssm/ssm.sh`. The `ssm` command is available immediately in any new shell — no `source ~/.zshrc` needed.

### 2. Configure

Run the interactive config command to add your first account. It will write to both `~/.ssm/config.json` and `~/.aws/credentials`:

```bash
ssm config
# → add → enter account name, AWS profile name, region
# → prompted to set AWS access key ID and secret
```

The `databases` object in `~/.ssm/config.json` is auto-populated on first `ssm db` use.

## Usage

```bash
ssm ssh      # SSH into an EC2 instance
ssm db       # Open an RDS tunnel
ssm config   # Manage account profiles and AWS credentials
ssm update   # Update ssm to the latest version
ssm help     # Show usage and config info
```

### ssm ssh

1. Select environment
2. Select application (discovered from EC2 `App` tag)
3. Select instance (auto-selected if only one)
4. Drops into an SSM shell session as `ubuntu`

### ssm db

1. Select environment
2. Select application
3. Select RDS instance (auto-selected if only one)
4. A stable local port is assigned on first use and saved to `config.json`
5. A temporary hostname alias (`<db-identifier>.tunnel`) is added to `/etc/hosts`
6. Tunnel opens — connect your DB client to `<db-identifier>.tunnel:<port>`
7. On exit (Ctrl+C), the `/etc/hosts` entry is removed automatically

### ssm config

Interactive menu with four actions:

| Action | Description |
|--------|-------------|
| `view` | Print `~/.ssm/config.json` and show masked AWS key IDs per account |
| `add` | Add a new account entry and optionally configure its AWS CLI credentials |
| `edit` | Edit `profile`, `region`, `aws-access-key`, or `aws-secret-key` for an account |
| `delete` | Remove an account and optionally delete the linked AWS CLI profile |

**add** prompts for:
- Account name (key in `~/.ssm/config.json`)
- AWS CLI profile name
- AWS region
- Access Key ID and Secret Access Key (optional — skippable)

**edit** field options:
- `profile` / `region` — updates `~/.ssm/config.json`
- `aws-access-key` — updates `~/.aws/credentials` via `aws configure set`
- `aws-secret-key` — updates `~/.aws/credentials` (input is hidden)

**delete** removes the account from `~/.ssm/config.json` and optionally strips the AWS CLI profile from `~/.aws/credentials` and `~/.aws/config`.

## AWS Requirements

### IAM Policy

Attach the following policy to the IAM user or role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DescribeEC2Instances",
      "Effect": "Allow",
      "Action": ["ec2:DescribeInstances"],
      "Resource": "*"
    },
    {
      "Sid": "DescribeRDSInstances",
      "Effect": "Allow",
      "Action": ["rds:DescribeDBInstances"],
      "Resource": "*"
    },
    {
      "Sid": "SSMStartSession",
      "Effect": "Allow",
      "Action": [
        "ssm:StartSession",
        "ssm:TerminateSession",
        "ssm:ResumeSession",
        "ssm:DescribeSessions",
        "ssm:GetConnectionStatus"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SSMPortForwarding",
      "Effect": "Allow",
      "Action": ["ssm:StartSession"],
      "Resource": [
        "arn:aws:ssm:*::document/AWS-StartInteractiveCommand",
        "arn:aws:ssm:*::document/AWS-StartPortForwardingSessionToRemoteHost"
      ]
    }
  ]
}
```

### EC2 Tags

EC2 instances must have:

| Tag | Value |
|-----|-------|
| `App` | app name (e.g. `adam`, `eva`, `hub`) |

### RDS Tags

RDS instances must have the same `App` tag as their corresponding EC2 instances.

### EC2 Instance Profile

Target EC2 instances must have the `AmazonSSMManagedInstanceCore` policy attached to their instance profile, and the SSM agent must be running.

## Config File Reference

`~/.ssm/config.json` structure:

```json
{
  "<environment-name>": {
    "profile": "<aws-cli-profile-name>",
    "region": "<aws-region>",
    "databases": {
      "<db-identifier>": <local-port>
    }
  }
}
```

`databases` is managed automatically — ports are assigned on first use and reused on subsequent runs. All other fields are managed via `ssm config`.

## Development

This repository is the source of truth for the `ssm` CLI. It previously lived in
[`supplycart/devops`](https://github.com/supplycart/devops) under `commands/`.

Pushes to `master` trigger `.github/workflows/deploy.yml`, which syncs `install.sh` and `ssm.sh`
to the `supplycart-cdn` R2 bucket under `shells/` — the paths that
`https://cdn.supplycart.my/shells/…` serves. Those URLs are hard-coded in `install.sh` and in
`ssm update`, so changing them breaks every existing install.

Publishing requires a `Production` environment on this repo with the variables
`CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_R2_CDN_BUCKET`, `CLOUDFLARE_R2_CDN_ID` and the secret
`CLOUDFLARE_R2_CDN_SECRET`.

To verify a release reached the CDN:

```bash
curl -fsSL https://cdn.supplycart.my/shells/ssm.sh | shasum
shasum ssm.sh   # must match
```
