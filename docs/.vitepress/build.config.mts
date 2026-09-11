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

  vite: {
    build: {
      rollupOptions: {
        output: {
          /**
           * Local search builds a chunk named after the virtual module
           * `@localSearchIndex`, and the CDN answers 403 to a URL with a literal
           * `@` in the path, so the browser cannot load it. Renaming the chunk
           * here rather than after the build means rollup writes the new name
           * into every reference itself.
           */
          chunkFileNames: (chunk) =>
            `assets/chunks/${(chunk.name || 'chunk').replace(/[^\w.-]/g, '_')}.[hash].js`,
        },
      },
    },
  },
})
