---
# https://vitepress.dev/reference/default-theme-home-page
layout: home
title: ssm
description: Connect to EC2, ECS, EKS and RDS through AWS Systems Manager, without a bastion host or open SSH ports.

hero:
  name: ssm
  text: AWS SSM Manager
  tagline: Shell into EC2 instances, ECS containers and EKS pods, and tunnel to RDS, through AWS Systems Manager. No bastion host, no open SSH ports.
  image:
    src: /supplycart.png
    alt: Supplycart
  actions:
    - theme: brand
      text: Install
      link: /install
    - theme: alt
      text: Commands
      link: /commands/overview
    - theme: alt
      text: GitHub
      link: https://github.com/supplycart/aws-ssm-manager

features:
  - title: ssm ssh
    details: Shell into an EC2 instance, or into an ECS or Fargate container through ECS Exec.
    link: /commands/ssh
  - title: ssm db
    details: Open an RDS tunnel on a stable local port, with a temporary hostname for your DB client.
    link: /commands/db
  - title: ssm pod
    details: Shell into an EKS pod, without touching your kubeconfig or current context.
    link: /commands/pod
  - title: Scriptable
    details: Every menu has a flag, so a destination you already know is a single command.
    link: /commands/overview
---
