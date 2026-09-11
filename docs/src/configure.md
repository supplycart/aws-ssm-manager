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
# → add → enter account name, AWS profile name, region
# → prompted to set AWS access key ID and secret
```

`add` asks for:

- Account name: the key in `~/.ssm/config.json`, and what you pass as `--env`
- AWS CLI profile name
- AWS region
- Access key ID and secret access key (optional, and skippable)

The `databases` section of the config is filled in automatically the first time
you use `ssm db`.

Your IAM user or role also needs the permissions in
[AWS requirements](/reference/aws-requirements), and the instances need an
`App` tag.

To view, edit or delete accounts later, see [ssm config](/commands/config).
