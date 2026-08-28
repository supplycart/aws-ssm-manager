# SSM Command

An interactive CLI tool for connecting to AWS EC2 instances, ECS containers, EKS pods, and RDS databases — without needing a bastion host or open SSH ports.

## Features

- Interactive environment, application, and instance selection using arrow keys
- SSH into any EC2 instance via SSM
- Detects ECS container instances and offers the host shell or a container shell
- Shell into ECS and Fargate containers via ECS Exec
- Shell into EKS pods via `ssm pod` (cluster → namespace → pod → container)
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
ssm ssh      # Shell into an EC2 instance or an ECS/Fargate container
ssm pod      # Shell into an EKS pod
ssm db       # Open an RDS tunnel
ssm config   # Manage account profiles and AWS credentials
ssm update   # Update ssm to the latest version
ssm help     # Show usage and config info
```

### ssm ssh

1. Select environment
2. Select application (discovered from the `App` tag on EC2 instances and ECS services)
3. If the app has both EC2 instances and ECS services, choose which to connect to
4. Select instance or container (auto-selected if only one)
5. Drops into an SSM shell session as `ubuntu`, or into the container via ECS Exec

**ECS detection.** After you pick an EC2 instance, `ssm ssh` checks whether it is registered
as an ECS container instance. If it is, you are told which cluster it belongs to and asked
whether you want the host shell (`sudo su - ubuntu`, as before) or a shell inside one of the
containers running on it. A plain EC2 instance is unaffected — same menus, same shell, no
extra prompt.

**Fargate.** Fargate services have no EC2 instance, so they never appeared in the app list
before. They are now discovered from their `App` tag and reachable through ECS Exec.

### ssm pod

1. Select environment
2. Select EKS cluster (auto-selected if only one)
3. Select namespace
4. Select pod (running pods only)
5. Select container (auto-selected if only one)
6. Drops into the container via `kubectl exec`

Pods are not reachable over SSM at all, so this path uses `kubectl` rather than Session
Manager — which is why it is a separate command instead of a branch of `ssm ssh`.

Credentials are fetched with `aws eks update-kubeconfig` and written to **`~/.ssm/kubeconfig`**.
Your `~/.kube/config` and your current kubectl context are never touched.

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
      "Sid": "ECSDiscoverAndExec",
      "Effect": "Allow",
      "Action": [
        "ecs:ListClusters",
        "ecs:ListServices",
        "ecs:ListTasks",
        "ecs:ListContainerInstances",
        "ecs:DescribeServices",
        "ecs:DescribeTasks",
        "ecs:ExecuteCommand",
        "tag:GetResources"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EKSDiscoverAndConnect",
      "Effect": "Allow",
      "Action": [
        "eks:ListClusters",
        "eks:DescribeCluster"
      ],
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

### ECS Tags

ECS **services** must carry the same `App` tag as EC2 instances. Discovery uses the Resource
Groups Tagging API (`tag:GetResources`) for speed; without that permission the tool falls
back to enumerating clusters and services, which is slower but needs no extra IAM.

### RDS Tags

RDS instances must have the same `App` tag as their corresponding EC2 instances.

### EC2 Instance Profile

Target EC2 instances must have the `AmazonSSMManagedInstanceCore` policy attached to their instance profile, and the SSM agent must be running.

### EKS Access

`ssm pod` needs `kubectl` (installed by `install.sh`) and IAM permission to describe the
cluster. Beyond IAM, your principal must also be mapped **inside** the cluster — either as
an access entry or in the `aws-auth` ConfigMap — with rights to list namespaces and pods
and to create `pods/exec`. Without that mapping the AWS calls succeed but `kubectl` is
denied; `ssm pod` reports this rather than failing with a raw error.

### ECS Exec

To shell into a container, the ECS service must be deployed with `enableExecuteCommand` and
its **task role** must allow `ssmmessages:CreateControlChannel`, `ssmmessages:CreateDataChannel`,
`ssmmessages:OpenControlChannel` and `ssmmessages:OpenDataChannel`. If exec is not enabled,
`ssm ssh` says so and prints the `aws ecs update-service` command that turns it on rather
than failing with a raw AWS error.

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
