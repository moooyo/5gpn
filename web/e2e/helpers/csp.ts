import type { Page } from '@playwright/test'
export function collectCSPViolations(page: Page) {
  const consoleErrors: string[] = []
  page.on('console', (msg) => {
    const t = msg.text()
    if (/Content Security Policy|Refused to (load|apply|execute|connect)/i.test(t)) consoleErrors.push(t)
  })
  page.addInitScript(() => {
    ;(window as any).__csp = []
    document.addEventListener('securitypolicyviolation', (e: any) => {
      ;(window as any).__csp.push(`${e.effectiveDirective || e.violatedDirective} ${e.blockedURI}`)
    })
  })
  return {
    consoleErrors,
    async all(): Promise<string[]> {
      const evt = await page.evaluate(() => (window as any).__csp || [])
      return [...consoleErrors, ...evt]
    },
  }
}
