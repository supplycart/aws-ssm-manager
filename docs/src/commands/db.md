---
title: ssm db
description: Open a tunnel to an RDS database through SSM port forwarding.
---

# ssm db

1. Select environment
2. Select application
3. Select RDS instance (auto-selected if only one)
4. A stable local port is assigned on first use and saved to `config.json`
5. A temporary hostname alias (`<db-identifier>.tunnel`) is added to
   `/etc/hosts`
6. Tunnel opens: connect your DB client to `<db-identifier>.tunnel:<port>`
7. On exit (Ctrl+C), the `/etc/hosts` entry is removed automatically

It works with PostgreSQL, MySQL and any other engine, since the tunnel only
forwards the port. Because the port stays the same between runs, you configure
your DB client once.

## Flags

`--env`, `--app`, `--db <identifier>`. The jump host is the first running
instance of the app; `--instance <id|Name>` picks a different one.

```sh
ssm db --env staging --app adam --db sc-staging-adam-rds
```
