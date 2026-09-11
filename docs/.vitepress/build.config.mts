import { defineConfig } from 'vitepress'

// refer: https://vitepress.dev/reference/site-config
export default defineConfig({
  /**
   * The site is uploaded into the CDN bucket next to install.sh and ssm.sh, so
   * it lives under that folder rather than at the root of a domain.
   *
   * refer: https://vitepress.dev/reference/site-config#base
   */
  base: '/shells/aws-ssm-manager/',
  srcDir: './src',
  /**
   * R2 serves objects by exact key: /install would not find install.html, so
   * links keep their .html extension.
   */
  cleanUrls: false,
})
