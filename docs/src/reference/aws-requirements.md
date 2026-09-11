---
title: AWS requirements
description: The IAM permissions, tags and instance setup ssm needs.
---

# AWS requirements

## IAM policy

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
      "Action": ["eks:ListClusters", "eks:DescribeCluster"],
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

## Tags

| Resource      | Tag   | Value                                  |
| ------------- | ----- | -------------------------------------- |
| EC2 instances | `App` | app name (e.g. `adam`, `eva`, `hub`)   |
| ECS services  | `App` | the same app name as its EC2 instances |
| RDS instances | `App` | the same app name as its EC2 instances |

ECS discovery uses the Resource Groups Tagging API (`tag:GetResources`) for
speed. Without that permission ssm falls back to enumerating clusters and
services, which is slower but needs no extra IAM.

## EC2 instance profile

Target EC2 instances must have the `AmazonSSMManagedInstanceCore` policy
attached to their instance profile, and the SSM agent must be running.

## EKS access

`ssm pod` needs `kubectl` (installed by the installer) and IAM permission to
describe the cluster. Beyond IAM, your principal must also be mapped **inside**
the cluster, either as an access entry or in the `aws-auth` ConfigMap, with
rights to list namespaces and pods and to create `pods/exec`. Without that
mapping the AWS calls succeed but `kubectl` is denied; `ssm pod` reports this
rather than failing with a raw error.

## ECS Exec

To shell into a container, the ECS service must be deployed with
`enableExecuteCommand` and its **task role** must allow
`ssmmessages:CreateControlChannel`, `ssmmessages:CreateDataChannel`,
`ssmmessages:OpenControlChannel` and `ssmmessages:OpenDataChannel`. If exec is
not enabled, `ssm ssh` says so and prints the `aws ecs update-service` command
that turns it on, rather than failing with a raw AWS error.
