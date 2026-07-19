import { defineConfig, devices } from '@playwright/test'

const serverPort = process.env.PLAYWRIGHT_PORT ?? '4173'
const serverHost = process.env.PLAYWRIGHT_HOST ?? '127.0.0.1'
const serverURL = `http://${serverHost}:${serverPort}`

/**
 * Playwright config for the 5gpn-dns console e2e gate.
 *
 * The desktop project exercises every route under the exact production CSP;
 * three iPhone-sized Chromium projects pin responsive drawer behavior,
 * touch targets, dialogs, and horizontal overflow. All projects serve the
 * prebuilt dist through e2e/server/csp-server.mjs.
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
    baseURL: serverURL,
    // Prevent a previously installed localhost PWA worker from serving stale
    // assets and producing results from an older production build.
    serviceWorkers: 'block',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },

  webServer: {
    command: `node e2e/server/csp-server.mjs ${serverPort} ${serverHost}`,
    url: serverURL,
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
        baseURL: serverURL,
      },
    },
    {
      name: 'iphone-15-393x852',
      testMatch: '**/mobile-*.spec.ts',
      use: {
        ...devices['Desktop Chrome'],
        viewport: { width: 393, height: 852 },
        deviceScaleFactor: 3,
        isMobile: true,
        hasTouch: true,
        baseURL: serverURL,
      },
    },
    {
      name: 'iphone-16-pro-402x874',
      testMatch: '**/mobile-*.spec.ts',
      use: {
        ...devices['Desktop Chrome'],
        viewport: { width: 402, height: 874 },
        deviceScaleFactor: 3,
        isMobile: true,
        hasTouch: true,
        baseURL: serverURL,
      },
    },
    {
      name: 'iphone-17-pro-max-440x956',
      testMatch: '**/mobile-*.spec.ts',
      use: {
        ...devices['Desktop Chrome'],
        viewport: { width: 440, height: 956 },
        deviceScaleFactor: 3,
        isMobile: true,
        hasTouch: true,
        baseURL: serverURL,
      },
    },
  ],
})
