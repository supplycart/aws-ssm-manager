import { defineConfig } from 'vitepress'
import markdownConfig from './markdown.config.mts'
import themeConfig from './theme.config.mts'
import siteMetadataConfig from './site-metadata.config.mts'
import buildConfig from './build.config.mts'

// refer: https://vitepress.dev/reference/site-config
export default defineConfig({
  ...buildConfig,
  ...siteMetadataConfig,

  themeConfig: themeConfig,
  markdown: markdownConfig,
})
