<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'

const INSTALL_URL = {
  macos: 'https://cdn.supplycart.my/shells/aws-ssm-manager/install.sh',
  windows: 'https://cdn.supplycart.my/shells/aws-ssm-manager/install.ps1',
}
// Read in the browser on every visit, so a new release shows up without a
// docs deploy.
const RELEASES_API =
  'https://api.github.com/repos/supplycart/aws-ssm-manager/releases?per_page=100'
const RELEASES_PAGE = 'https://github.com/supplycart/aws-ssm-manager/releases'
// Only plain release tags reach the command, since it is pasted into a shell.
const TAG_RE = /^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/

interface Release {
  tag: string
  url: string
  date: string
}

interface ApiRelease {
  tag_name: string
  html_url: string
  published_at: string
  draft: boolean
  prerelease: boolean
}

type Os = 'macos' | 'windows'
const os = ref<Os>('macos')

const releases = ref<Release[]>([])
const state = ref<'loading' | 'ready' | 'failed'>('loading')
const selected = ref('')

// Windows cannot take an argument through `irm | iex`, so a pinned install
// goes through the environment variable install.ps1 reads.
const command = computed(() => {
  if (os.value === 'windows') {
    const run = `irm ${INSTALL_URL.windows} | iex`
    return selected.value
      ? `$env:SSM_INSTALL_VERSION = '${selected.value}'; ${run}`
      : run
  }
  return (
    `bash <(curl -fsSL ${INSTALL_URL.macos})` +
    (selected.value ? ` ${selected.value}` : '')
  )
})

const lang = computed(() => (os.value === 'windows' ? 'powershell' : 'sh'))

const release = computed(() =>
  selected.value
    ? releases.value.find((r) => r.tag === selected.value)
    : releases.value[0]
)

function newestFirst(a: Release, b: Release): number {
  const x = a.tag.slice(1).split('.').map(Number)
  const y = b.tag.slice(1).split('.').map(Number)
  return y[0] - x[0] || y[1] - x[1] || y[2] - x[2]
}

function label(r: Release): string {
  const date = new Date(r.date)
  if (isNaN(date.getTime())) return r.tag
  const day = date.toLocaleDateString(undefined, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
  })
  return `${r.tag} — ${day}`
}

onMounted(async () => {
  // In onMounted, not at setup: this component is server-rendered at build
  // time and there is no navigator there.
  const platform =
    (navigator as unknown as { userAgentData?: { platform?: string } })
      .userAgentData?.platform ??
    navigator.platform ??
    ''
  if (/win/i.test(platform)) os.value = 'windows'

  try {
    const res = await fetch(RELEASES_API, {
      headers: { Accept: 'application/vnd.github+json' },
    })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const data: ApiRelease[] = await res.json()
    const list = data
      .filter((r) => !r.draft && !r.prerelease && TAG_RE.test(r.tag_name))
      .map((r) => ({ tag: r.tag_name, url: r.html_url, date: r.published_at }))
      .sort(newestFirst)
    if (!list.length) throw new Error('no releases')
    releases.value = list
    state.value = 'ready'
  } catch {
    state.value = 'failed'
  }
})
</script>

<template>
  <div class="version-picker">
    <div class="controls">
      <div class="os" role="group" aria-label="Platform">
        <button
          type="button"
          :aria-pressed="os === 'macos'"
          :class="{ active: os === 'macos' }"
          @click="os = 'macos'"
        >
          macOS
        </button>
        <button
          type="button"
          :aria-pressed="os === 'windows'"
          :class="{ active: os === 'windows' }"
          @click="os = 'windows'"
        >
          Windows
        </button>
      </div>

      <label for="ssm-version">Version</label>
      <select id="ssm-version" v-model="selected" :disabled="state !== 'ready'">
        <option value="">
          {{ state === 'ready' ? `Latest (${releases[0].tag})` : 'Latest' }}
        </option>
        <option v-for="r in releases" :key="r.tag" :value="r.tag">
          {{ label(r) }}
        </option>
      </select>
      <a
        v-if="release"
        class="notes"
        :href="release.url"
        target="_blank"
        rel="noreferrer"
        >Release notes</a
      >
    </div>

    <!-- Same markup as a VitePress code block, so it gets the theme's styling
         and copy button. -->
    <div :class="['vp-adaptive-theme', `language-${lang}`]">
      <button title="Copy Code" class="copy"></button>
      <span class="lang">{{ lang }}</span>
      <pre class="vp-code"><code>{{ command }}</code></pre>
    </div>

    <p v-if="selected" class="note">
      Installs {{ selected }} exactly. Running <code>ssm update</code> later
      moves it to the latest version.
    </p>
    <p v-else-if="state === 'loading'" class="note">Loading versions…</p>
    <p v-else-if="state === 'failed'" class="note">
      Couldn't load the version list, so only the latest is shown. Older
      versions are on the
      <a :href="RELEASES_PAGE" target="_blank" rel="noreferrer">releases page</a
      >:
      <template v-if="os === 'windows'">
        set <code>$env:SSM_INSTALL_VERSION</code> before the command, for
        example <code>$env:SSM_INSTALL_VERSION = 'v1.0.0'</code>.
      </template>
      <template v-else>
        add the tag after the command, for example
        <code>… install.sh) v1.0.0</code>.
      </template>
    </p>
  </div>
</template>

<style scoped>
.version-picker {
  margin: 16px 0;
}

.controls {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px 12px;
}

.controls label {
  font-weight: 600;
}

.controls .os {
  display: inline-flex;
  border: 1px solid var(--vp-c-divider);
  border-radius: 8px;
  overflow: hidden;
}

.controls .os button {
  padding: 4px 12px;
  font-size: 14px;
  color: var(--vp-c-text-2);
  background-color: var(--vp-c-bg-soft);
  transition:
    color 0.2s,
    background-color 0.2s;
}

.controls .os button.active {
  color: var(--vp-c-white);
  background-color: var(--vp-c-brand-1);
}

.controls select {
  appearance: auto;
  max-width: 100%;
  padding: 4px 8px;
  border: 1px solid var(--vp-c-divider);
  border-radius: 8px;
  background-color: var(--vp-c-bg-soft);
  color: var(--vp-c-text-1);
  font-size: 14px;
}

.controls .notes {
  margin-left: auto;
  font-size: 14px;
}

.version-picker div[class*='language-'] {
  margin-top: 12px;
}

/* Wrap the command so all of it is visible before it is pasted. The theme sets
   `white-space: pre` on the code element, so both elements need overriding. */
.version-picker div[class*='language-'] pre,
.version-picker div[class*='language-'] code {
  white-space: pre-wrap;
  overflow-wrap: anywhere;
}

.version-picker div[class*='language-'] code {
  width: auto;
  /* Keep the wrapped text clear of the copy button, which floats over it. */
  padding-right: 3rem;
}

.version-picker .note {
  margin: 8px 0 0;
  font-size: 14px;
  color: var(--vp-c-text-2);
}
</style>
