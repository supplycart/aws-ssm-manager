---
title: ssm ssh
description: Shell into an EC2 instance, or into an ECS or Fargate container.
---

# ssm ssh

Shell into an EC2 instance through SSM, or into an ECS or Fargate container
through ECS Exec.

1. Select environment
2. Select application (discovered from the `App` tag on EC2 instances and ECS
   services)
3. If the app has both EC2 instances and ECS services, choose which to connect
   to
4. Select instance or container (auto-selected if only one)
5. Drops into an SSM shell session as `ubuntu`, or into the container via ECS
   Exec (the container shell uses `bash` when the image has it, otherwise `sh`)

The environment menu shows each account's masked access key, such as
`staging (AKIA****WXYZ)`, so similarly named accounts are easy to tell apart.
Each choice stays on screen after its menu closes, whether you picked it, a
flag answered it, or it was the only option:

```
✓ Account: staging (AKIA****WXYZ)
✓ App: adam
✓ Instance: i-0adam000000000001 adam-web-1 (only one)
```

`ssm db` and `ssm pod` show their choices the same way.

## Flags

`--env` answers step 1, `--app` step 2, `--type ec2|ecs` step 3, and
`--instance` or `--container` step 4. `--instance` implies `--type ec2` and
`--container`/`--task` imply `--type ecs`, so `--type` is only needed to pick
the EC2 side without naming an instance. On an ECS container instance, `--host`
takes the host shell and `--container` takes the container shell, which is the
"host or container" question below.

```sh
ssm ssh --env staging --app adam
ssm ssh --env staging --app adam --instance web-01
ssm ssh --env staging --app adam --container php-fpm
```

## ECS container instances

After you pick an EC2 instance, `ssm ssh` checks whether it is registered as an
ECS container instance. If it is, you are told which cluster it belongs to and
asked whether you want the host shell or a shell inside one of the containers
running on it.

ECS container instances run the ECS-optimized AMI, so the host shell logs in as
`ec2-user` there and as `ubuntu` everywhere else. A plain EC2 instance is
unaffected: same menus, same `sudo su - ubuntu` shell, no extra prompt.

## Fargate

Fargate services have no EC2 instance. They are discovered from their `App` tag
and reached through ECS Exec, which must be
[enabled on the service](/reference/aws-requirements#ecs-exec).
