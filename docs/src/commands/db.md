---
title: ssm db
description: Open a tunnel to an RDS database through SSM port forwarding.
---

# ssm db

1. Select environment
2. Select application
3. Select RDS instance (auto-selected if only one)
4. A stable local port is assigned on first use and saved to `config.json`
5. Tunnel opens, and a banner prints the host and port to connect to
6. On exit (Ctrl+C), the tunnel closes

Connect your DB client to **whatever the banner prints**. That is the one thing
that differs between platforms:

| Platform | Host                     | Notes                                                                 |
| -------- | ------------------------ | --------------------------------------------------------------------- |
| macOS    | `<db-identifier>.tunnel` | added to `/etc/hosts` for the life of the tunnel, and removed on exit |
| Windows  | `127.0.0.1`              | the hosts file needs admin there, so ssm does not touch it            |

See [platform differences](/reference/platforms) for why.

## The `/etc/hosts` line (macOS)

ssm writes exactly one line per database, tagged so it can find it again:

```
127.0.0.1 sc-staging-adam-rds.tunnel # ssm-tunnel
```

- **Only that tagged line is ever removed.** Every other entry is left
  byte-for-byte as it was, including lines that look similar, such as
  `…-rds.tunnel.local`.
- **A line you wrote yourself is yours.** If `/etc/hosts` already maps the name
  to `127.0.0.1`, ssm adds nothing, and removes nothing when the tunnel closes.
- **Parallel tunnels share the line.** Each running `ssm db` holds a lease in
  `~/.ssm/tunnels/`, and the line goes when the **last** tunnel using it closes.
  Running two at once, to the same database or to different ones, never pulls a
  hostname out from under the other.
- A tunnel killed outright (`kill -9`, a crashed terminal) leaves its line and
  lease behind. The next `ssm db` for that database notices the lease is dead
  and cleans up after it.

It works with PostgreSQL, MySQL and any other engine, since the tunnel only
forwards the port. Because the port stays the same between runs, you configure
your DB client once.

## Flags

`--env`, `--app`, `--db <identifier>`. The jump host is the first running
instance of the app; `--instance <id|Name>` picks a different one.

```sh
ssm db --env staging --app adam --db sc-staging-adam-rds
```
