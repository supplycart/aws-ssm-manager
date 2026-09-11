---
title: Config file
description: The structure of ~/.ssm/config.json.
---

# Config file

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

`databases` is managed automatically: ports are assigned on first use and
reused on subsequent runs. All other fields are managed with
[ssm config](/commands/config).
