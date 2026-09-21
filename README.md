# SSM Command

A CLI tool for connecting to AWS EC2 instances, ECS containers, EKS pods, and RDS databases —
without needing a bastion host or open SSH ports. Interactive by default, fully scriptable with
flags. Runs on macOS and Windows 11.

**Docs: [cdn.supplycart.my/shells/aws-ssm-manager](https://cdn.supplycart.my/shells/aws-ssm-manager/index.html)**
— the install guide with a version picker, every command and its flags, and the AWS setup ssm
needs.

## Install

macOS:

```bash
bash <(curl -fsSL https://cdn.supplycart.my/shells/aws-ssm-manager/install.sh)          # latest
bash <(curl -fsSL https://cdn.supplycart.my/shells/aws-ssm-manager/install.sh) v1.1.0   # a specific release
```

Installs `awscli`, `fzf`, `jq`, `kubectl` and the AWS Session Manager plugin via Homebrew, and
links `/usr/local/bin/ssm` to `~/.ssm/ssm.sh`.

Windows 11:

```powershell
irm https://cdn.supplycart.my/shells/aws-ssm-manager/install.ps1 | iex

$env:SSM_INSTALL_VERSION = 'v1.1.0'; irm https://cdn.supplycart.my/shells/aws-ssm-manager/install.ps1 | iex
```

Installs PowerShell 7, `awscli`, `kubectl`, the Session Manager plugin and (optionally) `fzf` via
winget, writes `%USERPROFILE%\.ssm\ssm.ps1` and an `ssm.cmd` shim, puts that directory on your
user PATH, and creates Start Menu and Desktop shortcuts. No `jq`: PowerShell parses JSON itself.

A pinned install stays on its release until `ssm update`, which moves it to the latest.

Then add an AWS account with `ssm config`:

```bash
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

## Development

This repository is the source of truth for the `ssm` CLI. It previously lived in
[`supplycart/devops`](https://github.com/supplycart/devops) under `commands/`.

Run the same checks CI runs before opening a PR:

```bash
bash -n install.sh && bash -n ssm.sh && bash -n .github/scripts/release.sh && bash -n .github/scripts/docs_upload.sh
bash test/args_test.sh && bash test/release_test.sh && bash test/install_test.sh && bash test/docs_upload_test.sh && bash test/parity_test.sh

pwsh -Command '"ssm.ps1", "install.ps1" | ForEach-Object { $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $_), [ref]$null, [ref]$e); if ($e) { $e; exit 1 } }'
pwsh -File test/ssm_test.ps1 && pwsh -File test/install_ps_test.ps1
```

### Two implementations

`ssm.sh` (bash 3.2, macOS) and `ssm.ps1` (PowerShell 7, Windows 11) are two implementations of one
CLI. **Every command and every flag must exist in both.** `commands.manifest` is the source of
truth and `test/parity_test.sh` fails the required `test` check if either side disagrees with it.

Adding a flag is a change in four places: `commands.manifest`, `ssm.sh`'s `parse_args` call,
`ssm.ps1`'s `$SSM_COMMANDS` table, and the matching page under `docs/src/commands/`.

The differences that are deliberate are listed in `docs/src/reference/platforms.md`, and nowhere
else.

### Docs site

`docs/` is a [VitePress](https://vitepress.dev/) site set up like
[`supplycart/wiki`](https://github.com/supplycart/wiki): pages in `docs/src/`, the sidebar in
`docs/src/sidebar.mts`, and site config split across `docs/.vitepress/*.config.mts`. Every page
needs `title` and `description` frontmatter and a sidebar entry.

```bash
cd docs
pnpm install
pnpm dev       # http://localhost:5173/shells/aws-ssm-manager/
pnpm format    # CI runs pnpm format:check
pnpm build     # output in docs/.vitepress/dist
```

`.github/workflows/docs.yml` builds the site on every PR that touches `docs/`. On `master` it uploads
the build into the `supplycart-cdn` R2 bucket under `shells/aws-ssm-manager/`, next to the release
scripts:

- The upload never deletes, and `.github/scripts/docs_upload.sh` refuses a build that contains a
  `.sh` file or a `vX.Y.Z/` folder, so it can't overwrite anything a release put there.
- R2 serves objects by exact key, so the site is built with `cleanUrls: false` (pages end in
  `.html`), and links must name a page, never a folder.
- Each file is stored with an explicit content type, because the CDN sends `nosniff`.

A redirect rule on the `supplycart.my` zone (Cloudflare dashboard → Rules → Redirect Rules) sends
exactly `/shells/aws-ssm-manager` and `/shells/aws-ssm-manager/` to `…/index.html`. It matches
those two paths only: a prefix match would also redirect `install.sh` and `ssm update`.

The install page reads the release list from the GitHub API in the browser, so a new release shows
up there without a docs deploy.

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

Every version stays on the CDN, so `install.sh` installs any of them when given the tag. It
checks the version exists before installing anything:

```bash
bash <(curl -fsSL https://cdn.supplycart.my/shells/aws-ssm-manager/install.sh) v1.2.3
ssm version   # ssm v1.2.3
```

Up to v1.1.0 the scripts lived directly under `shells/`, and installs from then still run
`ssm update` against `shells/ssm.sh`. So every release also writes the latest `ssm.sh` and
`install.sh` to `shells/`. An old install's next `ssm update` picks up the new URL and never
reads the old path again. The releases made before the move are copied from `shells/vX.Y.Z/`
into `shells/aws-ssm-manager/vX.Y.Z/`, and the originals remain where they were.

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
