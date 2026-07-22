# 5GPN native extension manifest v1

5GPN accepts one extension format: a strict YAML document with
`apiVersion: 5gpn.io/v1` and `kind: Extension`. The manifest is a permission
request and an immutable execution description, not a general proxy
configuration language.

## Complete shape

```yaml
apiVersion: 5gpn.io/v1
kind: Extension

metadata:
  id: io.example.response-cleaner
  name: Response Cleaner
  version: 1.0.0
  description: Rewrites a bounded API response.

permissions:
  persistentStorage: false
  network:
    origins:
      - https://api.example.net

requirements:
  egressGroup:
    required: true

traffic:
  captureHosts:
    - api.example.com
    - "*.cdn.example.com"
  upstreamMappings:
    - host: api.example.com
      target: origin.example.net
  routingRules:
    - action: reject
      domainSuffix: ads.example.com
      allDomainKeywords:
        - tracker
      network: udp
      destinationPort: 443
    - action: direct
      ipCIDR: 203.0.113.7/32

settings:
  - key: mode
    type: select
    label: Cleaning mode
    description: Selects the response transformation profile.
    required: true
    options:
      - clean
      - full
    default: clean

actions:
  - id: clean-response
    phase: response
    match:
      hosts:
        - api.example.com
      schemes:
        - https
      methods:
        - GET
      pathRegex: ^/v1/items
      statusCodes:
        - 200
    script:
      source: ./clean.js
      bodyMode: text
      timeoutMs: 1000
      maxBodyBytes: 1048576
```

Unknown fields, duplicate keys, multiple YAML documents, aliases, anchors, and
merge keys are rejected. Extension IDs are stable lowercase dotted identifiers
from 3 to 40 bytes. The short limit keeps every authenticated Telegram
confirmation callback within its protocol boundary. Versions use semantic
version syntax.

## Traffic acquisition, routing, and egress

`traffic.captureHosts` is the only way an extension can request client traffic.
Entries are exact DNS names or constrained `*.example.com` wildcards. 5GPN
never infers hosts from a regular expression.

When an enabled extension and the global MITM master are active, the same
capture-host set is published atomically to:

1. the DNS overlay that returns the gateway address;
2. the constrained interception certificate SAN set; and
3. the reserved mihomo `MODULE-INTERCEPT` rules for ports 80 and 443.

Every action `match.hosts` and every upstream mapping host must be covered by
the same extension's `captureHosts`. The control plane validates this relation,
and the sidecar repeats it at runtime. A plugin cannot act on a host captured
only by another plugin.

An extension may declare at most 512 capture hosts, an action may match at most
512 hosts, and all enabled extensions may contribute at most 512 unique host
patterns to the interception certificate. These bounds include exact apex
names and wildcards separately.

Capture-host origin DNS is operator state, not a manifest capability. Every
import defaults to `trust`; the operator may select `china`. Mihomo continues
to query the `127.0.0.1:5354` loopback boundary. `china` forces the live China
group with its current ECS, while `trust` and non-extension hostnames use the
live trust group. The first enabled matching extension in execution order wins
overlaps. DNS sees a hostname only, so a URL path cannot choose a resolver.

`upstreamMappings` changes only the sidecar's upstream target. It preserves the
original HTTP Host and TLS SNI and rejects private, loopback, link-local, or
otherwise unsafe IPv4 targets. Every upstream TCP or UDP flow returns through
authenticated mihomo `intercept-egress`.

`traffic.routingRules` is a separate global gateway capability. It does not
acquire or decrypt traffic and it does not extend `captureHosts`. Each rule has
exactly one action, `reject` or `direct`, and cannot name a proxy group. A rule
may declare at most one of `domain`, `domainSuffix`, or `ipCIDR`, or may use a
domain-keyword expression without one. `domainKeywords` contains 2–8 sorted,
unique alternatives combined with OR; `allDomainKeywords` contains 1–8 sorted,
unique requirements combined with AND. The two groups may be combined but may
not repeat a keyword. A single keyword uses `allDomainKeywords`. Optional
`network` is `tcp` or `udp`, and optional `destinationPort` is 1–65535. Empty
declared fields, non-canonical stored values, unsafe matcher characters, and
duplicate normalized rules are rejected.

An extension may declare at most 256 rules, and enabled extensions may declare
at most 2048 in total. Rules follow explicit extension execution order and
mihomo first-match semantics. They are published after the fixed gateway
UDP/443 guard and before `MODULE-INTERCEPT` capture rules, so a reviewed
`direct` match deliberately bypasses both the normal operator target and
sidecar capture. They exist only while both the extension and MITM master are
enabled. The one enable confirmation lists every normalized rule and authorizes
the complete snapshot; there is no second routing-only confirmation. Reordering
requires a before/after confirmation because it can change action, egress, and
capture-DNS, and global routing precedence. Rules affect only traffic that
reaches mihomo on the DNS-steering gateway; they cannot block a hard-coded IP
path that bypasses it.

An extension may declare `requirements.egressGroup.required: true`, but the
manifest and script never name or choose an arbitrary group. The operator selects one
existing mihomo proxy group or `DIRECT` before enable. Extensions without that requirement
use the operator's terminal mihomo target unless an optional binding was
selected. Ordered, host-and-port-scoped `intercept-egress` rules enforce the
binding, and the first matching bound extension in the operator's explicit
execution order wins. A missing or removed group makes the extension not ready
and never silently falls back to DIRECT or another group. A separately reviewed
`routingRules` action may still explicitly select `direct` for its own matcher.

The same execution order is used for request and response actions, top to
bottom. Every action sees the output produced by earlier actions in its phase.
Import appends an extension to the order; delete removes it; the Console and
trusted private-chat Telegram bot can move an extension up or down with a
revision-protected, explicitly confirmed complete reorder.

## Origin-scoped network permission

`permissions.network.origins` is an optional list of exact HTTP(S) origins. An
origin contains only scheme, canonical hostname, and effective port. Userinfo,
paths other than `/`, query, fragment, wildcard hosts, IP literals, localhost,
and private names are rejected. Default ports are canonicalized, so
`https://api.example.net` and `https://api.example.net:443` request the same
permission.

The permission is part of the immutable snapshot digest. It provides no global
`fetch`, XHR, socket, DNS, cookie jar, or ambient credentials. It authorizes
both the synchronous `context.network.request` function and a request-phase URL
rewrite to an exact declared origin. Every such call or rewritten request
travels through authenticated mihomo SOCKS5. A cross-origin rewritten URL must
be canonical absolute HTTP(S), match the declared origin exactly, contain no
userinfo or fragment, and never downgrade an HTTPS request to HTTP. A
same-origin rewrite from the captured origin remains inside the extension's
capture-host boundary. After an earlier action moves the request to an approved
external origin, a later action may execute against or rewrite within that
current origin only when its own extension also declares that exact origin.
Redirects from `context.network.request` are returned to the script rather than followed.
Fixed process-wide time, body, header, call-count, and concurrency bounds apply;
they are runtime safety limits, not manifest-controlled permissions.

Once granted, a script can deliberately send any request, response, setting,
or storage data visible to it to an approved origin. A rewritten captured
request sends its complete method, decoded body, and end-to-end headers,
potentially including `Cookie` or `Authorization`; framing and hop-by-hop fields
remain runtime-owned. Every management surface's enable review must list the
origins and state these consequences explicitly.
Adding or changing an origin changes the snapshot and therefore requires a
disabled update followed by a new enable confirmation.

## Typed settings

Supported setting types are:

- `text`: a bounded string;
- `select`: one value from 1–64 declared options;
- `boolean`: `true` or `false`;
- `number`: a finite number with optional `min` and `max`; and
- `location`: `{longitude, latitude, accuracy}` with accuracy from 1 to 100000
  metres.

Required settings must be complete before enable. A `location` setting is
rendered by the Console with city search, a draggable OpenStreetMap point,
accuracy visualization, and direct coordinate fields. The browser calls one
authenticated same-origin city-search endpoint; that bounded server projection
contacts the fixed Nominatim origin only after an explicit Search action and
never forwards the Console bearer token. The Telegram bot accepts either the
client's native location message or explicit longitude, latitude, and accuracy.
It warns before collection that coordinates pass through Telegram and the
Telegram Bot API. An omitted Telegram accuracy becomes the conservative
100000-metre maximum. Telegram does not embed or proxy the Console's full map.

## Script actions

An action phase is `request` or `response`. Its structured matcher contains:

- `hosts`: a non-empty subset of `captureHosts`;
- `schemes`: `http`, `https`, or both;
- optional uppercase HTTP `methods`;
- a required RE2 `pathRegex`, matched against path plus query; and
- optional response `statusCodes` from 100 through 599.

The script declares exactly one of:

- `source`: an HTTPS URL, or a relative URL when the manifest itself was
  installed by URL; or
- `inline`: source embedded in the manifest.

`bodyMode` is `none`, `text`, or `binary`. Binary bodies are `Uint8Array`
values. `timeoutMs` is 50–30000 and `maxBodyBytes` is 1024–67108864. Source,
aggregate script, response, and VM resource limits are enforced independently.

Every script defines one global entry point:

```javascript
function transform(context) {
  return {
    response: {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
      trailers: { 'Grpc-Status': '0' },
      body: '{"ok":true}',
    },
  }
}
```

The context contains:

```text
context.phase
context.request.url
context.request.method
context.request.headers
context.request.body          # only when bodyMode requests it
context.response.status       # response actions only
context.response.headers      # response actions only
context.response.trailers     # response actions only
context.response.body         # response actions only when requested
context.settings
context.storage               # only with persistentStorage permission
context.network.request       # only with declared and confirmed origins
```

A request action may return a `request` patch or a synthetic `response` patch.
A response action may return only a `response` patch. Either phase may return
`{abort: true}`, `null`, or `undefined`. Unknown result fields fail closed.
Changed request URLs must remain inside that action's extension capture-host
boundary unless an exact declared network origin authorizes the cross-origin
rewrite under the constraints above.

Response trailers are exposed after the upstream body is read and may be
replaced through `response.trailers`. Request patches cannot create trailers.
Trailer names and values use the same bounded, control-character-safe shape as
headers, while framing and otherwise forbidden trailer fields are rejected.
The sidecar declares and publishes them correctly over HTTP/1.1, HTTP/2, and
HTTP/3, including when an H2/H3 upstream did not announce them before an H1
downstream response starts.

Scripts receive console logging but no ambient network, filesystem, process,
timer, socket, module loader, or Go object. The optional storage object exposes
bounded `get`, `set`, `delete`, and `clear` methods scoped to the extension ID.
When network origins were declared, a script can make a bounded request:

```javascript
const result = context.network.request({
  url: 'https://api.example.net/v1/data',
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ value: context.settings.value }),
})
```

The returned object contains `url`, `status`, `headers`, `trailers`, binary
`body`, and a `text` field when the body is valid UTF-8. Non-2xx responses are returned
normally; permission, transport, or bound failures throw an exception that the
script may catch.

## Installation and updates

**Install from URL** accepts one HTTPS manifest and snapshots its referenced
scripts. **Add locally** accepts one pasted or uploaded manifest; local
manifests use inline scripts or absolute HTTPS script URLs. Both actions install
the extension disabled.

The top-level Console Marketplace page and the trusted private-chat Telegram
bot also accept explicit HTTPS marketplace indexes using the strict
`5gpn.io/marketplace/v1` JSON contract. A marketplace is only a bounded
discovery list. The daemon fetches and caches it through the same redirect and
post-resolution SSRF guard, while both surfaces render only the authenticated
normalized projection. Adding or refreshing a marketplace never installs,
updates, enables, or executes an extension.

An optional source display name is local operator text only. It does not replace
the index metadata identity or prove publisher ownership. It never changes the
remote index, manifest, or script digests. The separate local normalized-source
snapshot digest does include the display name so a Telegram confirmation for
one reviewed label cannot authorize writing another.

Selecting a marketplace entry refetches its manifest through this same native
parser and verifies the index's manifest and script SHA-256 digests, byte sizes,
identity, and derived capability summary. A mismatch aborts before local state
changes. A successful selection creates the ordinary disabled immutable
snapshot and still requires the complete settings, permission, capture-host,
routing-rule, execution-order, and egress review described above. The
marketplace capability summary carries a required `routingRuleCount`, but the
actual normalized rules come only from the refetched manifest snapshot.
Marketplace descriptions,
tags, and licenses are informational and do not replace source review.

An update check refetches only the installed manifest URL. The candidate must
keep the same `metadata.id`. The management surface displays the candidate
version, snapshot digest, capture hosts, actions, and settings before
replacement. Replacement requires the current extension to be disabled, refetches the exact
reviewed digest, preserves still-valid setting values by key and type, and
leaves the new snapshot disabled. Enabling reviews capture hosts, network
origins, every exact normalized routing rule, execution position, and the current operator egress binding before
the transaction publishes certificates, mihomo rules, sidecar state, and the
DNS overlay.

## Telegram management confirmations

The Telegram bot is a trusted extension-management endpoint only for
allowlisted administrators in private chats. It supports marketplace source
add, refresh, browse, and removal; marketplace and HTTPS-URL installation;
pasted-text local import; uninstall; enable and disable; every typed setting;
`location`; operator egress binding; complete execution-order changes; and
update checks and applies. It calls the same marketplace and extension managers
as the Console and has no private state or relaxed parser. Installation and
update application always leave the extension disabled.

Browsing and update checks may be read-only, but every state-changing Telegram
action uses a two-step review. The bot first renders the complete normalized
impact relevant to the operation: source, identity, old and new versions,
immutable snapshot digest, settings, capture hosts, permissions, exact network
origins, exact routing rules, execution position, operator egress binding, and action match/execution
metadata with script digests, plus the resulting enabled/runtime state. Script
bodies remain available through
the separate authenticated snapshot review rather than being placed in every
Telegram mutation prompt. If Telegram message limits require pagination or a
protected document, the confirmation control appears only after the complete
review.

The confirmation callback carries only an opaque reference to a server-side,
short-lived, one-use record. That record is bound to the allowlisted
administrator user ID, exact private chat ID, exact operation payload, and all
applicable concurrency proofs. Extension changes bind the complete sidecar
revision and affected immutable snapshot digest. Marketplace source changes
bind the marketplace document revision and exact normalized index snapshot
digest. Marketplace installation and extension update also bind the candidate
extension snapshot digest. Expiry, replay, cross-user or cross-chat use, a
changed revision, or any snapshot/index digest mismatch fails closed and
requires a new review.

Every review of a candidate or installed extension lists each declared network
origin. Before enable, it also states that the script can send any decrypted
request, response, setting, or storage data visible to it to every listed
origin, and may rewrite a captured request there with its method, decoded body,
and end-to-end headers, including possible cookies or authorization. Enable
review uses the same single confirmation for the complete
snapshot, including all listed routing rules. Reorder review shows the complete
before/after order and warns that routing first-match may change. Approval of
one immutable snapshot never grants a changed origin or routing-rule set.

Project-maintained examples, including Apple WLOC, live in the separate
`moooyo/5gpn-extensions` catalog. The core repository intentionally contains no
extension source. The official marketplace index is:

```text
https://moooyo.github.io/5gpn-extensions/marketplace/v1/index.json
```

The public repository also exposes Apple WLOC directly at:

```text
https://raw.githubusercontent.com/moooyo/5gpn-extensions/main/apple-wloc/extension.yaml
```
