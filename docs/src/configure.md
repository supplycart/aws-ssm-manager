---
title: Configure
description: Add your first AWS account to ssm.
---

# Configure

ssm keeps its accounts in `~/.ssm/config.json`. Add the first one with
`ssm config`, which writes both that file and your AWS CLI credentials in
`~/.aws/credentials`:

```sh
ssm config
# → add → account name, then pick (or type) an AWS CLI profile, then a region
# → a new profile asks for its access key ID and secret
```

`add` asks for:

- **Account name**: your label for the AWS account, such as `staging`. It is
  the key in `~/.ssm/config.json`, and what you pass as `--env`.
- **AWS CLI profile**: the saved access keys in `~/.aws` that ssm calls AWS
  with. Pick one you already have, or type a new name to create it.
- **AWS region**: pick it from a list. Type a city, such as `singapore`, to
  filter it.

An account and a profile are separate things. The account is ssm's name for
where you connect; the profile is the credentials it connects with. Several
accounts can share one profile.

The `databases` section of the config is filled in automatically the first time
you use `ssm db`.

Your IAM user or role also needs the permissions in
[AWS requirements](/reference/aws-requirements), and the instances need an
`App` tag.

To view, edit or delete accounts later, see [ssm config](/commands/config).
