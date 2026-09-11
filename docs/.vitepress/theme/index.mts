import DefaultTheme from 'vitepress/theme'
import type { Theme } from 'vitepress'
import VersionPicker from './components/VersionPicker.vue'

// refer: https://vitepress.dev/guide/extending-default-theme
export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    app.component('VersionPicker', VersionPicker)
  },
} satisfies Theme
