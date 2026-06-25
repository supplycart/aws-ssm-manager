# SSM Command

An interactive CLI tool for connecting to AWS EC2 instances and RDS databases via AWS Systems Manager (SSM), without needing a bastion host or open SSH ports.

## Features

- Interactive environment, application, and instance selection using arrow keys
- SSH into any EC2 instance via SSM
- Open RDS tunnels via SSM port forwarding (supports PostgreSQL, MySQL, and any engine)
- Auto-discovers apps and instances from EC2/RDS `App` tags
- Stable local ports per database — configure your DB client once
- Temporary `/etc/hosts` alias while the DB tunnel is active (e.g. `sc-staging-adam-rds.tunnel`)

## Prerequisites

### 1. Install dependencies

```bash
bash commands/install.sh
```

This installs `awscli`, `fzf`, `jq`, and the AWS Session Manager plugin via Homebrew (installing Homebrew itself if needed).

### 2. Configure AWS CLI profiles

Ensure your `~/.aws/credentials` and `~/.aws/config` have profiles matching the environments in `config.json`:

```ini
# ~/.aws/config
[profile your-staging-profile]
region = ap-southeast-5

[profile your-production-profile]
region = ap-southeast-5
```

### 3. Set up config.json

Copy the example config and fill in your values:

```bash
cp commands/config.example.json commands/config.json
```

Edit `config.json` with your AWS profile names and region. The `databases` object is auto-populated on first use — do not commit `config.json`.

### 4. Add the alias to your shell

Add this to your `~/.zshrc`:

```zsh
alias ssm="<path-to-repo>/commands/ssm.sh"
```

Then reload:

```bash
source ~/.zshrc
```

## Usage

```bash
ssm ssh    # SSH into an EC2 instance
ssm db     # Open an RDS tunnel
ssm help   # Show usage and config info
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

`config.json` structure:

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

`databases` is managed automatically — ports are assigned on first use and reused on subsequent runs.
