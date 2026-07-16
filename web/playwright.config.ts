import { defineConfig, devices } from '@playwright/test'

/**
 * Playwright config for the 5gpn-dns console e2e gate.
 *
 * The desktop project exercises every route under the exact production CSP;
 * the 390x844 Chromium project pins responsive drawer behavior and horizontal
 * overflow. Both serve the prebuilt dist through e2e/server/csp-server.mjs.
 */
export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  workers: process.env.CI ? 2 : undefined,
  reporter: [['list'], ['html', { open: 'never', outputFolder: 'playwright-report' }]],
  outputDir: 'e2e/test-results',

  use: {
    baseURL: 'http://127.0.0.1:4173',
    // Prevent a previously installed localhost PWA worker from serving stale
    // assets and producing results from an older production build.
    serviceWorkers: 'block',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },

  webServer: {
    command: 'node e2e/server/csp-server.mjs 4173',
    url: 'http://127.0.0.1:4173',
    reuseExistingServer: !process.env.CI,
    timeout: 30_000,
  },

  projects: [
    {
      name: 'desktop',
      testIgnore: '**/mobile-*.spec.ts',
      use: {
        ...devices['Desktop Chrome'],
        viewport: { width: 1440, height: 900 },
        baseURL: 'http://127.0.0.1:4173',
      },
    },
    {
      name: 'mobile-390x844',
      testMatch: '**/mobile-*.spec.ts',
      use: {
        ...devices['Desktop Chrome'],
        viewport: { width: 390, height: 844 },
        isMobile: true,
        hasTouch: true,
        baseURL: 'http://127.0.0.1:4173',
      },
    },
  ],
})
