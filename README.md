# SSM Command

A CLI tool for connecting to AWS EC2 instances, ECS containers, EKS pods, and RDS databases —
without needing a bastion host or open SSH ports. Interactive by default, fully scriptable with
flags.

## Features

- Interactive environment, application, and instance selection using arrow keys
- Every menu has a flag that replaces it, so a known destination is one command: `ssm ssh --env staging --app adam`
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
bash <(curl -fsSL https://cdn.supplycart.my/shells/aws-ssm-manager/install.sh)
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
ssm version  # Print the installed version
ssm help     # Show usage and config info
```

### Skipping the menus

Every prompt has a flag that answers it. Supply the flags you know and the rest still come up as
menus, so `ssm ssh` on its own behaves exactly as it always has:

```bash
ssm ssh                                   # fully interactive
ssm ssh --env staging                     # skips the account menu
ssm ssh --env staging --app adam          # no prompts at all if the app has one instance
ssm ssh --env staging --app adam --container php-fpm
ssm db  --env staging --app adam --db sc-staging-adam-rds
ssm pod --env staging -n default --pod api-7d9f
```

| Command | Flags |
|---------|-------|
| all | `--env\|-e <name>` (alias `--account`), `--help\|-h` |
| `ssh` | `--app <name>`, `--type ec2\|ecs`, `--instance <id\|Name>`, `--container <name>`, `--task <id>`, `--host` |
| `db` | `--app <name>`, `--db <identifier>`, `--instance <id\|Name>` |
| `pod` | `--cluster <name>`, `--namespace\|-n <ns>`, `--pod <name>`, `--container\|-c <name>` |
| `config` | see [ssm config](#ssm-config) |

`--flag value` and `--flag=value` both work. `ssm <command> --help` prints that command's flags.

A value that doesn't exist is an error listing the valid ones — never a re-prompt — so a fully
flagged command can't stall waiting for input:

```
$ ssm ssh --env staging --app adm
Error: no app 'adm' in account staging.
Available:
  adam
  eva
  hub
```

Instances match on either their id or their `Name` tag, so `--instance i-0abc123` and
`--instance web-01` both work. If `--container` matches several running tasks, `ssm` lists them
and asks you to add `--task <id>`.

### ssm ssh

1. Select environment
2. Select application (discovered from the `App` tag on EC2 instances and ECS services)
3. If the app has both EC2 instances and ECS services, choose which to connect to
4. Select instance or container (auto-selected if only one)
5. Drops into an SSM shell session as `ubuntu`, or into the container via ECS Exec
   (the container shell uses `bash` when the image has it, otherwise `sh`)

Non-interactively: `--env` answers step 1, `--app` step 2, `--type ec2|ecs` step 3, and
`--instance` or `--container` step 4. `--instance` implies `--type ec2` and `--container`/`--task`
imply `--type ecs`, so `--type` is only needed to pick the EC2 side without naming an instance.
On an ECS container instance, `--host` takes the host shell and `--container` takes the container
shell, which is the "host or container" question below.

**ECS detection.** After you pick an EC2 instance, `ssm ssh` checks whether it is registered
as an ECS container instance. If it is, you are told which cluster it belongs to and asked
whether you want the host shell or a shell inside one of the containers running on it.
ECS container instances run the ECS-optimized AMI, so the host shell logs in as `ec2-user`
there and as `ubuntu` everywhere else. A plain EC2 instance is unaffected — same menus,
same `sudo su - ubuntu` shell, no extra prompt.

**Fargate.** Fargate services have no EC2 instance, so they never appeared in the app list
before. They are now discovered from their `App` tag and reachable through ECS Exec.

### ssm pod

1. Select environment
2. Select EKS cluster (auto-selected if only one)
3. Select namespace
4. Select pod (running pods only)
5. Select container (auto-selected if only one)
6. Drops into the container via `kubectl exec`

Non-interactively: `--env`, `--cluster`, `--namespace`/`-n`, `--pod`, `--container`/`-c`.

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

Non-interactively: `--env`, `--app`, `--db <identifier>`. The jump host is the first running
instance of the app; `--instance <id|Name>` picks a different one.

### ssm config

Run `ssm config` for the menu, or name the action directly:

```bash
ssm config view   [--env <name>]
ssm config add    --env <name> [--profile <p>] [--region <r>]
                  [--access-key <k>] [--secret-key -] [--skip-credentials]
ssm config edit   --env <name> [--profile <p>] [--region <r>]
                  [--access-key <k>] [--secret-key -]
ssm config delete --env <name> [--yes] [--delete-profile]
```

`edit` applies every field flag you pass in one go. `delete` still asks for confirmation unless
you pass `--yes`, and keeps the AWS CLI profile unless you pass `--delete-profile`.

**Secrets are never taken as a flag value** — that would record them in your shell history and
expose them in `ps`. Pass them one of these two ways instead:

```bash
SSM_AWS_SECRET_KEY="$SECRET" ssm config add --env staging --profile sc-staging \
  --region ap-southeast-5 --access-key AKIA...

echo "$SECRET" | ssm config edit --env staging --secret-key -
```

The four actions:

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

Run the same checks CI runs before opening a PR:

```bash
bash -n install.sh && bash -n ssm.sh && bash -n .github/scripts/release.sh
bash test/args_test.sh && bash test/release_test.sh
```

### Releases

`master` accepts changes only through pull requests, and only after the `test` check passes.
Every merge is released by `.github/workflows/deploy.yml`:

1. **Version.** The last `vX.Y.Z` tag gets a patch bump. Label the PR `release:minor` or
   `release:major` before merging for a bigger one. The first release is `v1.0.0`.
2. **Tag.** The workflow checks that the release-tag ruleset is active, stamps the version into
   `ssm.sh` (`SSM_VERSION`), commits that on top of the merged commit and pushes it as the tag
   `vX.Y.Z`. The tag is protected from the moment it exists. The release commit is reachable only
   from the tag, so `master` always reads `SSM_VERSION="dev"`.
3. **Upload.** `ssm.sh` and `install.sh` go to the `supplycart-cdn` R2 bucket, first under
   `shells/aws-ssm-manager/vX.Y.Z/` and then under `shells/aws-ssm-manager/`, which is what
   `ssm update` and the install command fetch. Those URLs are hard-coded in `install.sh` and in
   `ssm update`, so moving them needs a migration like the one described below.
4. **Release.** A GitHub release `vX.Y.Z` with generated notes and both scripts attached.

A failed run can be re-run: it finds the tag it already pushed for that commit and carries on
from there. Running the workflow by hand from `master` releases the latest commit if it has not
been tagged yet, with the `bump` input taking the place of the PR labels.

Every version stays on the CDN, so an older one can be installed directly:

```bash
curl -fsSL https://cdn.supplycart.my/shells/aws-ssm-manager/v1.2.3/ssm.sh -o ~/.ssm/ssm.sh
chmod +x ~/.ssm/ssm.sh
ssm version   # ssm v1.2.3
```

`shells/aws-ssm-manager/vX.Y.Z/install.sh` is kept too, but it still downloads the latest `ssm.sh`.

Up to v1.0.0 the scripts lived directly under `shells/`, and installs from then still run
`ssm update` against `shells/ssm.sh`. So every release also writes the latest `ssm.sh` and
`install.sh` to `shells/`. An old install's next `ssm update` picks up the new URL and never
reads the old path again. v1.0.0 itself is copied into `shells/aws-ssm-manager/v1.0.0/`, and
the original remains at `shells/v1.0.0/`.

Publishing requires a `Production` environment on this repo with the variables
`CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_R2_CDN_BUCKET`, `CLOUDFLARE_R2_CDN_ID` and the secret
`CLOUDFLARE_R2_CDN_SECRET`, plus access to the org secret `SUPPLYCART_BOT_TOKEN` (see
[Repository rulesets](#repository-rulesets)).

To verify a release reached the CDN:

```bash
curl -fsSL https://cdn.supplycart.my/shells/aws-ssm-manager/ssm.sh | grep '^SSM_VERSION='
gh release view --json tagName --jq .tagName   # must match
```

### Repository rulesets

Both rulesets are managed in the GitHub UI under **Settings → Rules → Rulesets**:

| Ruleset | Protects |
|---------|----------|
| `master: pull requests only` | `master`: no direct pushes, force pushes or deletion. Changes arrive by PR (squash or rebase) with a passing `test` check. |
| `release tags: v*.*.*` | `v*.*.*` tags: only the `bot` team can create them (in practice the deploy workflow), and nobody can move or delete them. |

The `test` check is the job id in `.github/workflows/test.yml`, so renaming that job blocks
every PR.

GitHub doesn't accept GitHub Actions as a ruleset bypass actor, so the deploy workflow checks
out and pushes release tags with the org secret `SUPPLYCART_BOT_TOKEN`. The only bypass on the
tag ruleset is the org's `bot` team, which needs write access to this repo. Every member of
that team can create release tags, so keep only automation accounts in it.

To remove a tag that should not exist, an admin sets the release-tag ruleset to `disabled`,
deletes the tag, and sets it back to `active`. The deploy refuses to release while it is off.
