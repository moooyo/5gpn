// English catalog — the authoritative shape. zh.ts is typed `typeof en`, so
// every key here MUST have a counterpart in zh.ts (tsc enforces it).
const en = {
  common: {
    cancel: 'Cancel',
    saving: 'Saving…',
    save: 'Save',
    add: 'Add',
    edit: 'Edit',
    delete: 'Delete',
    running: 'Running',
    loading: 'Loading…',
    backendPending: 'Pending backend (SP-A)',
    errorTitle: 'Something went wrong',
    errorBody: 'The page hit an unexpected error. Reloading usually fixes it.',
    reload: 'Reload',
    pagePrev: 'Prev',
    pageNext: 'Next',
    pageOf: 'Page {{page}} / {{count}}',
  },
  nav: {
    group: {
      system: 'Kernel & System',
      overview: 'Overview',
      parse: 'Parse',
      // Group now holds only the unified 策略规则 item. Deliberately NOT
      // 'Policy' or 'Policy Rules' — both collide with sibling nav labels
      // (nav.policyRules) and Sidebar renders group + item
      // labels as sibling text nodes, so an identical string trips
      // `getByText` "multiple elements" in chrome.test.tsx.
      rules: 'Rules',
    },
    overview: 'Dashboard',
    policyRules: 'Policy Rules',
    logs: 'DNS Log',
    resolveTest: 'Diagnostic test',
    mihomo: 'mihomo',
    mihomoConfig: 'mihomo Config',
    settings: 'Settings',
    primary: 'Primary navigation',
    openMenu: 'Open navigation',
    closeMenu: 'Close navigation',
  },
  topbar: {
    logout: 'Log out',
    language: 'Language',
    theme: 'Theme',
    light: 'Light',
    dark: 'Dark',
    system: 'System',
    admin: 'admin',
    superAdmin: 'Super Admin',
    consoleTag: 'Console',
    kernelDns: 'DNS server',
    sub: {
      overview: 'Live monitoring · QPS / traffic / connections',
      logs: 'Recent 5gpn-dns resolution history · decisions & outcomes',
      resolveTest: "Enter any domain to simulate 5gpn-dns's resolution decision",
      policyRules: 'Unified intent rules — one matcher → block/direct/proxy in the DNS engine',
      mihomo: 'Kernel health + live logs · read-only, deep ops in zashboard',
      mihomoConfig: 'Edit the whole effective mihomo config · six infrastructure invariants required',
      settings: 'System and service configuration',
    },
  },
  settings: {
    upstreams: 'Upstream DNS',
    upstreamsChina: 'Domestic group (china)',
    upstreamsTrust: 'Foreign group (trust)',
    upstreamsHint:
      'Domestic entries are plain-UDP IPs. Foreign entries are a bare IP (plain UDP, e.g. 22.22.22.22) or serverName@IP (DoT, e.g. dns.google@8.8.8.8). Changes apply immediately — no restart.',
    upstreamsSave: 'Save & apply',
    upstreamsSaved: 'Applied — the live resolver groups were hot-swapped.',
    upstreamsSaveFailed: 'Save failed.',
    ecs: 'Domestic ECS',
    ecsSubnet: 'Client egress IP',
    ecsHint:
      'Domestic (china-group) queries carry this subnet as EDNS Client Subnet, so CN CDNs schedule answers near the clients’ carrier/region. Check ip.cn on the phone over CELLULAR data and paste the IP here — it is normalised to its /24 on save. Leave empty to disable ECS. Applies immediately, no restart.',
    ecsSave: 'Save & apply',
    ecsSaved: 'Applied — domestic queries now carry {{subnet}}.',
    ecsDisabled: 'Disabled — domestic queries no longer carry ECS.',
    ecsSaveFailed: 'Save failed.',
    tgbot: 'Telegram bot',
    tgbotStatus: 'Status',
    tgbotStateStopped: 'Stopped',
    tgbotState_disabled: 'Disabled',
    tgbotState_starting: 'Connecting',
    tgbotState_healthy: 'Healthy',
    tgbotState_degraded: 'Degraded',
    tgbotToken: 'Bot token',
    tgbotTokenPlaceholder: 'paste the token from @BotFather',
    tgbotTokenKeep: 'token set — leave blank to keep it',
    tgbotTokenHint:
      'From @BotFather (/newbot). Saving validates it against Telegram and hot-restarts just the bot — the daemon keeps serving DNS. The token is never shown again; leave blank to change only the admins.',
    tgbotAdmins: 'Admin user IDs',
    tgbotAdminsHint:
      'Only these Telegram numeric user IDs may control the bot. An admin can DM the bot /id to learn theirs. Empty = the bot runs but denies everyone.',
    tgbotSave: 'Save & apply',
    tgbotSaved: 'Telegram bot configuration applied.',
    tgbotSaveFailed: 'Save failed.',
    // Task 4.3 — Settings page card grid (DoT service / console / Telegram bot / upstream DNS / ECS / about strip)
    greenfieldTip: 'Managed by the CLI/SP-C for now',
    dotService: 'DoT service',
    dotDomain: 'DoT domain',
    cert: "Let's Encrypt certificate",
    certValid: 'Valid',
    certExpired: 'Expired',
    certError: 'Certificate broken',
    certPort: ':853',
    certDaysRemaining: 'expires in {{count}} day(s)',
    consoleTitle: 'Console',
    listenPort: 'Listen port',
    listenPortHint: 'Exposed via the mihomo :443 SNI split',
    adminAccount: 'Admin account',
    changePassword: 'Change password',
    tgbotNeedToken: 'Enter a bot token before enabling the bot.',
    tgbotAdminsPlaceholder: 'comma-separated numeric IDs, e.g. 123456789,987654321',
    aboutTitle: '5GPN Console',
    aboutVersion: '5gpn-dns {{version}}',
  },
  errors: {
    network: 'Network error — the control server is unreachable.',
    authRequired: 'Authentication required',
    tokenRejected: 'Token rejected — check the value printed by install.sh.',
    rateLimited: 'Rate limited — slow down and try again in a moment.',
    blocked: 'Too many failed login attempts — this address is blocked for ~{{minutes}} min.',
    requestFailed: 'Request failed ({{status}}).',
    backendPending: 'Backend not ready yet (pending SP-A)',
  },
  auth: {
    title: '5GPN Console',
    tokenLabel: 'Access token',
    submit: 'Sign in',
    hint: 'Enter the access token printed by install.sh to sign in.',
  },
  format: {
    uptimeD: '{{count}}d',
    uptimeH: '{{count}}h',
    uptimeM: '{{count}}m',
    uptimeS: '{{count}}s',
    justNow: 'just now',
    mAgo: '{{count}}m ago',
    hAgo: '{{count}}h ago',
    dAgo: '{{count}}d ago',
  },
  verdicts: {
    // Neutral last-resort fallback label (see log-columns.tsx's
    // UNKNOWN_DECISION / resolve-test-decision.ts) for when neither `reason`
    // nor `verdict` is a recognized value — should not happen against a
    // well-behaved backend.
    noVerdict: 'no verdict',
  },
  overview: {
    // Task 5.2 — Overview/Dashboard page, trimmed in B3. LIVE-only: QPS and
    // decision split from /api/stats. The former current-exit card and
    // traffic-preview cards were dropped (their backend endpoints were
    // removed in SP-2) — egress switching is now the operator's raw mihomo
    // config (UP-4), not a console feature.
    intro: 'QPS and the decision split below are live, derived from /api/stats.',
    live: 'Live',
    paused: 'Paused',
    pause: 'Pause',
    resume: 'Resume',
    qps: 'QPS',
    qpsLive: 'QPS (live)',
    decisionDistribution: 'Decision split',
    decision: {
      block: 'Blocked',
      forceDirect: 'Force-direct',
      blacklist: 'Force-proxy',
      chnrouteCn: 'CN direct',
      chnrouteForeign: 'Foreign proxy',
    },
    // "A档" dashboard charts — still LIVE SNAPSHOTS from /api/stats, added on
    // top of the QPS/decision-split cards above (no new backend fields).
    cacheHitRate: 'Cache hit rate',
    upstreamHealth: 'Upstream health & latency',
    upstreamHealthOk: 'OK',
    upstreamHealthErr: 'Error',
    upstreamHealthLatency: 'Avg latency',
    upstreamHealthChina: 'china',
    upstreamHealthTrust: 'trust',
    arbitration: 'CN vs foreign split',
    arbitrationCn: 'CN direct',
    arbitrationForeign: 'Foreign proxy',
  },
  resolveTest: {
    domainLabel: 'Test domain',
    run: 'Test',
    running: 'Testing…',
    examples: 'Examples',
    ruleLabel: 'Matched rule',
    sourceLabel: 'Resolution source',
    answerLabel: 'Answer',
    decisionPath: 'Decision path',
    blocked: '(blocked)',
    groupChina: 'Domestic UDP',
    groupTrust: 'Trust DoT',
    // Pill text for each of the 5 reason-driven outcomes (same concepts as
    // logs.decision.*).
    label: {
      block: 'Blocked',
      forceDirect: 'Force-direct',
      blacklist: 'Force-proxy',
      chnrouteCn: 'CN direct',
      chnrouteForeign: 'Foreign proxy',
    },
    // Numbered decision-path step text per reason — wording modeled on the
    // design handoff's decide() (lines ~495-515); `generic` is the
    // single-step fallback used when `reason` is missing/unrecognized
    // (derived from the coarser `verdict` instead).
    steps: {
      block: ['Matched the block domain set', '5gpn-dns returns NXDOMAIN', 'The client never opens a connection'],
      forceDirect: [
        'Matched the force-direct allowlist',
        'Resolved via the trust resolver for the real IP',
        'Result: direct, bypassing the gateway',
      ],
      blacklist: [
        'Matched the blacklist denylist',
        '5gpn-dns returns the gateway IP',
        'The connection is steered to the proxy egress',
      ],
      chnrouteCn: [
        'No allow/deny match — falls to chnroute arbitration',
        'Concurrent query: domestic UDP ‖ trust DoT',
        'Domestic answer IP is in chnroute — adopted, direct',
      ],
      chnrouteForeign: [
        'No allow/deny match — falls to chnroute arbitration',
        'Concurrent query: domestic UDP ‖ trust DoT',
        'Answer IP is not in chnroute — returns the gateway IP, proxied',
      ],
      generic: 'Result: {{verdict}}',
    },
  },
  logs: {
    intro:
      'Live view of the resolver’s recent queries. Only the last 5 minutes are kept, in memory — nothing is written to disk.',
    searchPlaceholder: 'Filter by domain or client IP…',
    loading: 'Loading log…',
    loadFailed: 'Could not load the query log.',
    emptyTitle: 'No entries',
    emptyHint: 'No queries matched in the last 5 minutes. The view refreshes automatically.',
    pause: 'Pause',
    resume: 'Resume',
    paused: 'paused',
    live: 'live',
    colTime: 'Time',
    colName: 'Name',
    colReason: 'Matched rule',
    colDecision: 'Decision',
    colIps: 'Result IP',
    colDuration: 'Duration',
    // Decision label + color for a row come from `reason` (amendment A-H1),
    // NOT `verdict` — verdict only carries {block,direct,proxy} and
    // collapses the design's 5 labels / 4 colors down to 3. The last three
    // keys are the generic fallback used when `reason` is missing/unknown.
    decision: {
      forceDirect: 'Force-direct',
      blacklist: 'Force-proxy',
      chnrouteCn: 'CN direct',
      chnrouteForeign: 'Foreign proxy',
      direct: 'Direct',
      proxy: 'Proxy',
      block: 'Blocked',
    },
  },
  // UP-3 (B1-B4) — 策略规则 (Policy Rules): the unified intent-rule console
  // over `/api/policy/rules` + `/api/policy/fallback`. Each rule is one
  // matcher (domain / domain-suffix / domain-keyword / subscription) → one
  // intent (block/direct/proxy), compiled to the DNS engine only — UP-4 made
  // the policy strictly binary: a proxy intent carries no selector, and what
  // happens to gateway-bound traffic afterwards is the operator's raw mihomo
  // config. Replaces the old DNS-rules (`rules.*`) and rule-subscription
  // (`subscriptions.*`) namespaces, both removed.
  policyRules: {
    applyHint: 'Edits save right away — the compiled policy only reloads after you Apply.',
    newRule: 'Add rule',
    apply: 'Apply',
    applying: 'Applying…',
    applyOk: 'Applied — resolver policy reloaded.',
    applyFailed: 'Apply failed.',
    loadFailed: 'Could not load policy rules.',
    saveFailed: 'Save failed.',
    deleteTitle: 'Delete policy rule',
    deleteConfirm: 'Delete the rule for "{{name}}"?',
    deleteOk: 'Rule deleted.',
    deleteFailed: 'Delete failed.',
    dialog: {
      addTitle: 'Add policy rule',
      editTitle: 'Edit policy rule',
      kindLabel: 'Matcher kind',
      valueLabel: 'Value',
      urlLabel: 'URL',
      formatLabel: 'Format',
      intervalLabel: 'Interval',
      intentLabel: 'Intent',
      enabledLabel: 'Enabled',
      errValueRequired: 'Enter a value.',
      errUrlInvalid: 'Enter a valid http(s) URL.',
      saveFailed: 'Save failed.',
      createOk: 'Rule added.',
      editOk: 'Rule saved.',
    },
    kind: {
      domain: 'Domain (exact)',
      'domain-suffix': 'Domain suffix',
      'domain-keyword': 'Domain keyword',
      subscription: 'Subscription',
    },
    intent: {
      block: 'Block',
      direct: 'Direct',
      proxy: 'Proxy',
    },
    fallback: {
      title: 'Fallback policy',
      hint: 'What happens to a query that misses every rule above.',
      policy: {
        auto: 'Auto',
        direct: 'Direct',
        gateway: 'Gateway',
      },
      policyHint: {
        auto: 'If the resolved answer contains a domestic IP, go direct — otherwise, route through the gateway.',
        direct: 'Always resolve direct, never through the gateway.',
        gateway: 'Always route through the gateway.',
      },
      loadFailed: 'Could not load the fallback policy.',
      saveFailed: 'Save failed.',
      saveOk: 'Fallback policy saved.',
    },
    table: {
      colMatcher: 'Matcher',
      colIntent: 'Intent',
      colEnabled: 'Enabled',
      moveUp: 'Move up',
      moveDown: 'Move down',
      filterAll: 'All',
      searchPlaceholder: 'Search matcher value…',
      reorderDisabledHint: 'Reorder is disabled while a filter is active — clear the search/intent filter to reorder rules.',
      empty: 'No rules match the current filter.',
    },
  },
  mihomo: {
    intro: 'Read-only kernel monitoring — health + live logs. Connections, traffic, and per-node views live in zashboard.',
    healthTitle: 'mihomo kernel',
    healthLoading: 'Checking kernel health…',
    healthFailed: 'Could not reach the mihomo kernel.',
    metaBadge: 'Meta',
    openZashboard: 'Open zashboard (deep ops)',
    connected: 'Live logs connected',
    disconnected: 'Reconnecting…',
    pause: 'Pause',
    resume: 'Resume',
    paused: 'paused',
    live: 'live',
    colLevel: 'Level',
    colMessage: 'Message',
    emptyTitle: 'No log lines yet',
    emptyHint: 'Waiting for the mihomo kernel to emit log lines…',
  },
  mihomoConfig: {
    intro:
      'Edit the raw mihomo config as one whole document — there is no daemon-owned region to protect anymore. The server enforces the six infrastructure invariants below and will refuse any edit that deletes one of them.',
    loadFailed: 'Failed to load the mihomo config.',
    editorLabel: 'mihomo config (YAML)',
    controllerReachable: 'Controller reachable',
    controllerUnreachable: 'Controller unreachable',
    controllerUnauthenticated: 'Controller reachable, but the secret was rejected',
    appliedAt: 'Last applied {{time}}',
    apply: 'Validate & apply',
    applying: 'Validating…',
    applyOk: 'Applied — mihomo reloaded the new config.',
    applyFailed: 'Validation failed.',
    reset: 'Restore default',
    resetConfirmTitle: 'Restore the default mihomo config?',
    resetConfirmBody:
      'This overwrites your edits with the seed default (which already satisfies every required invariant) and re-applies it — use it to recover from a broken edit.',
    resetOk: 'Restored the default config.',
    resetFailed: 'Restore failed.',
    invariantsTitle: 'Required infrastructure (present-or-reject)',
    invariants: {
      controller: { name: 'Controller', desc: 'external-controller bound to the loopback controller (127.0.0.1:9090).' },
      sniproxy: { name: 'sniproxy inbound', desc: 'a tunnel listener on port 443 targeting 127.0.0.1:443.' },
      dns: { name: 'Our DNS', desc: 'a dns block whose nameserver includes the egress broker udp://127.0.0.1:5354.' },
      console: {
        name: 'Console SNI split',
        desc: 'the console domain routes publicly DIRECT to its loopback panel; the SPA and /ios/ are public while /api/* still requires a bearer token.',
      },
      zash: {
        name: 'zash SNI split',
        desc: 'the zash domain mapped to its loopback panel, with a whitelist-gated DIRECT rule and REJECT-DROP guard.',
      },
      antiloop: { name: 'Anti-loop REJECT-DROP', desc: 'an IP-CIDR REJECT-DROP guard for the gateway itself.' },
    },
  },
}

export default en
