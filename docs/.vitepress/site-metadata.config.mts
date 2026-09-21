import { defineConfig } from 'vitepress'

// refer: https://vitepress.dev/reference/site-config#site-metadata
export default defineConfig({
  title: 'ssm',
  description:
    'Connect to EC2, ECS, EKS and RDS through AWS Systems Manager, without a bastion host or open SSH ports.',
  lang: 'en-US',
  head: [
    // head links are not prefixed with `base`, unlike page links.
    [
      'link',
      {
        rel: 'icon',
        type: 'image/svg+xml',
        href: '/shells/aws-ssm-manager/aws-ssm.svg',
      },
    ],
  ],
})
