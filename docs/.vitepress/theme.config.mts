import { DefaultTheme } from 'vitepress'
import socialLinks from '../src/socialLinks.mts'
import sidebar from '../src/sidebar.mts'
import nav from '../src/nav.mts'

// refer: https://vitepress.dev/reference/default-theme-config
export default {
  logo: '/aws-ssm.svg',
  siteTitle: 'ssm',
  socialLinks,
  nav,
  sidebar,
  search: {
    provider: 'local', // refer: https://vitepress.dev/reference/default-theme-search
  },
  outline: {
    level: [2, 3], // refer: https://vitepress.dev/reference/default-theme-config#outline
  },
  editLink: {
    pattern:
      'https://github.com/supplycart/aws-ssm-manager/edit/master/docs/src/:path',
    text: 'Edit this page on GitHub',
  },
  footer: {
    message: 'macOS (Apple Silicon and Intel) · Windows 11',
  },
} satisfies DefaultTheme.Config
