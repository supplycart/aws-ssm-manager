// Link to named pages, never to a folder: R2 has no index document, so a link
// ending in `/` would not load.
export default [
  {
    text: 'Getting started',
    items: [
      { text: 'Install', link: '/install' },
      { text: 'Configure', link: '/configure' },
    ],
  },
  {
    text: 'Commands',
    items: [
      { text: 'Overview and flags', link: '/commands/overview' },
      { text: 'ssm ssh', link: '/commands/ssh' },
      { text: 'ssm pod', link: '/commands/pod' },
      { text: 'ssm db', link: '/commands/db' },
      { text: 'ssm config', link: '/commands/config' },
      { text: 'ssm uninstall', link: '/commands/uninstall' },
    ],
  },
  {
    text: 'Reference',
    items: [
      { text: 'AWS requirements', link: '/reference/aws-requirements' },
      { text: 'Config file', link: '/reference/config-file' },
      { text: 'Platform differences', link: '/reference/platforms' },
    ],
  },
]
