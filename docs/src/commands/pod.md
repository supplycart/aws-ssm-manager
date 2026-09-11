---
title: ssm pod
description: Shell into a container in an EKS pod.
---

# ssm pod

1. Select environment
2. Select EKS cluster (auto-selected if only one)
3. Select namespace
4. Select pod (running pods only)
5. Select container (auto-selected if only one)
6. Drops into the container via `kubectl exec`

## Flags

`--env`, `--cluster`, `--namespace`/`-n`, `--pod`, `--container`/`-c`.

```sh
ssm pod --env staging -n default --pod api-7d9f
```

## How it connects

Pods are not reachable over SSM at all, so this path uses `kubectl` rather than
Session Manager, which is why it is a separate command instead of a branch of
`ssm ssh`.

Credentials are fetched with `aws eks update-kubeconfig` and written to
**`~/.ssm/kubeconfig`**. Your `~/.kube/config` and your current kubectl context
are never touched.

Your AWS principal also needs access inside the cluster; see
[EKS access](/reference/aws-requirements#eks-access).
