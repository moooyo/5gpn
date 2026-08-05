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
  network: true

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
      entry: native
      timeoutMs: 1000
      maxBodyBytes: 1048576
```

Unknown fields, duplicate keys, multiple YAML documents, aliases, anchors, and
merge keys are rejected. Extension IDs are stable lowercase dotted identifiers
from 3 to 40 bytes. The short limit keeps route parameters, state keys, and
review projections bounded. Versions use semantic version syntax.

## Traffic acquisition, routing, and egress

`traffic.captureHosts` is the only way an extension can request client traffic.
Entries are exact DNS names or constrained `*.example.com` wildcards. 5GPN
never infers hosts from a regular expression.

When an enabled extension and the global MITM master are active, the same
capture-host set is consumed atomically by:

1. the DNS overlay that returns the gateway address;
2. the constrained interception certificate SAN set; and
3. the in-process TCP capture policy for ports 80 and 443.

Every action `match.hosts` and every upstream mapping host must be covered by
the same extension's `captureHosts`. The control plane validates this relation,
and the engine repeats it at runtime. A plugin cannot act on a host captured
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

An `upstreamMappings` entry takes one of three target forms.

An **address** (`203.0.113.7`) or an **alias** (`origin.example.net`) changes
the engine's upstream target. It preserves the original HTTP Host and TLS SNI.
An address target rejects private, loopback, link-local, CGNAT, and otherwise
unsafe IPv4 addresses; an alias is a name, so the same intent cannot be enforced
for it and a name that resolves into a private range is an accepted consequence.
Every upstream connection returns through mihomo's in-process inner dialer and
current rule evaluation.

A **resolver** form (`server:1.1.1.1`, up to four comma-separated specs) names
nameservers rather than a destination. It changes where the monolith resolver
resolves the mapped name, and the engine never dials it as an upstream target:
capture still leaves through the
extension's ordinary egress binding. Each spec uses the same grammar as an
operator upstream — `IP[:port]` for plain UDP, `name@IP[:port]` for DoT,
`https://host/path@IP[:port]` for DoH — and the address each one dials is held
to the same scope refusal an address target gets. A DoH endpoint hostname is
never resolved, so only the pinned address is checked.

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
mihomo first-match semantics. They are evaluated after the fixed gateway
UDP/443 guard and before TCP capture, so a reviewed
`direct` match deliberately bypasses both the normal operator target and
extension capture. They exist only while both the extension and MITM master are
enabled. The one enable confirmation lists every normalized rule and authorizes
the complete snapshot; there is no second routing-only confirmation. Reordering
requires a before/after confirmation because it can change action, egress, and
capture-DNS, and global routing precedence. Rules affect only traffic that
reaches mihomo on the DNS-steering gateway; they cannot block a hard-coded IP
path that bypasses it.

An extension may declare `requirements.egressGroup.required: true`, but the
manifest and script never name or choose an arbitrary group. The operator
selects one existing mihomo proxy group or `DIRECT` before enable. Extensions
without that requirement use the operator's terminal mihomo target unless an optional binding was
selected. The in-process traffic policy applies the selected group to the
engine's inner dial, and the first matching bound extension in the operator's
explicit execution order wins. A missing or removed group makes the extension not ready
and never silently falls back to DIRECT or another group. A separately reviewed
`routingRules` action may still explicitly select `direct` for its own matcher.

The same execution order is used for request and response actions, top to
bottom. Every action sees the output produced by earlier actions in its phase.
Import appends an extension to the order; delete removes it; the Console can
move an extension up or down with a revision-protected, explicitly confirmed
complete reorder.

## Network permission

`permissions.network: true` is the whole grant. It authorizes the synchronous
`context.network.request` function and a request-phase URL rewrite to any
origin. There is no origin list: the field used to accept either an exact list
or an unbounded `any`, and the two were alternatives, so an extension whose
script reaches operator-chosen hosts while one of its actions rewrites to a
fixed one could satisfy neither half. Every review now states that the extension
may reach the network, and cannot state where.

Every other guard is unchanged. The request URL is still canonicalized, IP
literals and unsafe or private hosts are still refused, and the request still
leaves through mihomo's in-process inner dialer. Redirects from
`context.network.request` are returned to the script rather than followed. Fixed
process-wide time, body, header, call-count, and concurrency bounds apply; they
are runtime safety limits, not manifest-controlled permissions.

The permission is part of the immutable snapshot digest. It provides no global
`fetch`, XHR, socket, DNS, cookie jar, or ambient credentials. A cross-origin
rewritten URL must be canonical absolute HTTP(S), contain no userinfo or
fragment, and never downgrade an HTTPS request to HTTP. A same-origin rewrite
from the captured origin stays inside the extension's capture-host boundary and
needs no grant. After an earlier action moves the request to an external origin,
a later action may execute against or rewrite within that current origin only
when its own extension also holds the grant.

Once granted, a script can deliberately send any request, response, setting, or
storage data visible to it to any host it can resolve. A rewritten captured
request sends its complete method, decoded body, and end-to-end headers,
potentially including `Cookie` or `Authorization`, to a host the manifest never
names; framing and hop-by-hop fields remain runtime-owned. Every management
surface's enable review must state these consequences explicitly. Taking or
dropping the grant changes the snapshot and therefore requires a disabled update
followed by a new enable confirmation.

An extension holding the grant reaches the network through one unbounded egress
authorization rather than a destination allowlist. The immutable in-process
policy revalidates each request against the current document and live mihomo
group set before dialing. Explicit destination bindings win first; otherwise
the authorizing extension's selected group is used. Missing or removed groups
fail closed, including for pooled transports after their authorization changes.

## HTTP/3 boundary

Native interception supports plain HTTP and TLS/H1/H2 only. `mitm.http3` is an
explicit capability marker whose only valid value is `false`; a management write
attempting `true` is rejected without changing the document revision. Fresh and
explicitly reset mihomo seeds contain one fixed global UDP/443 `REJECT`, and the
controller rule-management API refuses to disable it. A fallback-capable client may
retry over TCP and enter the normal capture path. An H3-only client fails.

This guard covers only UDP destination port 443 that reaches the gateway. It
does not disable ordinary UDP forwarding or QUIC sniffing on other configured
ports such as `:5060`, and it is not a host firewall.

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
never forwards the controller secret. The read-only Telegram bot does not edit
extension settings or collect locations.

A `location` value reaches a script nested under its own setting key, so it
cannot drive a published proxy-compat bundle: those are written against Loon's
`[Argument]` block, which is flat, and spell a coordinate as three scalar
arguments. A bundle reading `$argument.longitude` against a `location` setting
finds nothing and silently runs on its own defaults.

So the Console offers the same map for the flat form. When an extension
declares `text` or `number` settings keyed exactly `longitude` and `latitude`
-- with an optional `accuracy` -- it renders one picker above them that writes
those keys instead of a location object. The three fields remain editable on
their own, and what the script receives is unchanged: three flat values. A
`text` coordinate is written back as a string, because those bundles guard with
`argument.longitude && …` and would drop a numeric `0` as falsy.

This is a Console affordance, not a manifest declaration. It writes only the
keys the operator could type by hand, so it costs an unwanted map at worst and
never a wrong value, and no part of the engine contract changes.

## Script actions

An action phase is `request` or `response`. Its structured matcher contains:

- `hosts`: a non-empty subset of `captureHosts`;
- `schemes`: `http`, `https`, or both;
- optional uppercase HTTP `methods`;
- a required RE2 `pathRegex`, matched against path plus query; and
- optional response `statusCodes` from 100 through 599.

An action declares exactly one of seven kinds. Six are declarative and never
reach the JavaScript runtime — they are dispatched before a VM is created:

- `reject`: `true`, which aborts the exchange;
- `mock`: a synthetic response (`status`, `headers`, and at most one of `body`
  or `base64Body`). Omitting both produces an empty body. `body` contributes
  its UTF-8 bytes; `base64Body` is standard padded Base64 and contributes its
  decoded bytes. Either representation is bounded at 1 MiB by its own limit
  rather than by `maxBodyBytes`, because the body is declared here rather than
  read off the wire;
- `headers`: `set` and `remove` maps, applied to whichever message the phase
  owns;
- `rewrite`: `pattern`, `to`, and optional `status` (302 or 307). Request phase
  only — its executor rewrites the request URL, which the response phase has no
  way to honour;
- `replaceBody`: `pattern`, `to`, and optional `valueMap`. Requires `bodyMode`
  `text` or `binary`, since it edits a body it has to be given;
- `jq`: one expression, at most 32768 bytes, requiring `bodyMode: text`. A
  document whose shape the expression cannot act on — a top-level array where an
  object was expected, `"data": []` standing in for an object — skips the action
  rather than failing the exchange, the same as a body that is not JSON at all;
- a script, declaring exactly one of:
  - `source`: an HTTPS URL, or a relative URL when the manifest itself was
    installed by URL; or
  - `inline`: source embedded in the manifest.

`{{settings.key}}` in a `rewrite.to` or `replaceBody.to` is substituted with
that setting's rendered value, once. A substituted value is data, not more
template, so a value that contains a placeholder keeps it literally. An
unresolvable key, or a value with no `valueMap` entry, declines the action
rather than substituting an empty string.

`enabledWhen` gates an action on a setting: `{key, equals}`, where `key` names a
required `boolean` or `select` setting of the same extension and `equals` is one
of its declared values. Only those two types may be gated — a `number`,
`text`, or `location` comparison would be against a rendered string an author
cannot reliably predict, and a gate that never opens is silent.

`bodyMode` is `none`, `text`, or `binary`, and `timeoutMs` is 50–30000 and
`maxBodyBytes` is 1024–67108864, for every kind. `timeoutMs` bounds only the jq
and script kinds in practice, since the other five return before a deadline
could apply; `maxBodyBytes` bounds the message an action reads, so a `mock`,
which reads none, is not sized by it. Binary bodies are `Uint8Array`
values. Source,
aggregate script, response, and VM resource limits are enforced independently.
`bodyMode` controls only whether the input projection contains a body; it does
not restrict which valid patch the action may return. Replacement and synthetic
result bodies remain subject to both the action limit and the process-wide body
limit. For a fixed-length, identity-coded H1/H2 request whose matching actions
all use `none`, actions may execute before the request body is consumed. A
header-only result can then stream the original body and late trailers, while a
URL rewrite still requires the complete decoded body and a replacement drains
the original body to preserve its late trailers without materializing it.

`entry` selects the script contract. It is `native` by default, which is the
`transform(context)` entry point described below. `proxy-compat` instead runs a
published proxy-client bundle: the script returns immediately, does its work
asynchronously, and signals completion by calling `$done`. The mode is declared
rather than inferred, because it changes how an action completes and what its
result means.

## Script contracts

### Native

Every native script defines one global entry point:

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
context.network.request       # only with the confirmed network grant
context.network.requestAsync  # the same, returning a promise
```

A request action may return a `request` patch or a synthetic `response` patch.
A response action may return only a `response` patch. Either phase may return
`{abort: true}`, `null`, or `undefined`. Unknown result fields fail closed.
Changed request URLs must remain inside that action's extension capture-host
boundary unless the extension holds the network grant, which authorizes the
cross-origin rewrite under the constraints above.

Response trailers are exposed after the upstream body is read and may be
replaced through `response.trailers`. Request patches cannot create trailers.
Trailer names and values use the same bounded, control-character-safe shape as
headers, while framing and otherwise forbidden trailer fields are rejected.
The engine declares and publishes them correctly over HTTP/1.1 and HTTP/2,
including when an H2 upstream did not announce them before an H1 downstream
response starts. HTTP/3 downstream interception is unsupported.

Scripts receive bounded `console.log`/`info`/`warn`/`error` logging and
action-scoped timers, but no ambient network, filesystem, process, socket,
module loader, or Go object. Console output and structured action
completion/error/timeout events
live only in mihomo's 1000-entry memory ring and the authenticated
`/5gpn/interception/logs` projection used by `/plugin-logs`; they are not written
to journald or another file. Event
URLs retain only scheme, host, and path. The optional storage object exposes
bounded `get`, `set`, `delete`, and `clear` methods scoped to the extension ID.
With the network grant, a script can make a bounded request:

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

`context.network.requestAsync` takes the same options and returns a promise, so
a script can issue several requests at once:

```javascript
const [first, second] = await Promise.all([
  context.network.requestAsync({ url: 'https://api.example.net/v1/a' }),
  context.network.requestAsync({ url: 'https://api.example.net/v1/b' }),
])
```

It resolves to the same object and rejects rather than throwing, so `await`
inside `try`/`catch` reads the way the synchronous form does. Both entry points
draw on one per-action call budget, so mixing them cannot double a script's
allowance, and the same origin, body, header, and egress rules apply to each.

The synchronous form holds the VM for the whole round trip, so it fails
immediately when the process-wide concurrency bound is saturated; an awaited
request waits for a slot instead, because it can settle later. The action
deadline bounds both.

### Proxy-compat

`entry: proxy-compat` runs a published proxy-client bundle unmodified. The
runtime presents itself as Loon: the engine defines `$loon`, and the bundles
built on `@nsnanocat/util` select their runtime by probing globals in a fixed
order — `$task`, `$loon`, `$rocket`, `Egern`, then
`$environment["surge-version"]` — so they take their Loon branch. No Surge,
Quantumult X, or Egern global is defined, and `$environment` reports
`loon-version` rather than `surge-version`.

Loon is the right persona because its `[Argument]` block is typed and Loon
hands a bundle a **decoded object**. Serializing settings into a string instead
is what every encoding bug in this layer came from: each publisher parses that
string differently — a quoted `key="value"` form, JSON, a bare query — and a
bundle that mis-parses `$argument` does not fail, it silently runs on its own
defaults.

A bundle receives:

```text
$loon             the persona version string
$environment      { "loon-version": … }
$script           { startTime }
$request          { url, method, headers, body? }
$response         { status, headers, body }, undefined in the request phase
$argument         typed settings, as a decoded object
$done(result)     completion; result is the response projection
$persistentStore  read(key) / write(value, key), with the storage permission
$httpClient       get|post|put|delete|head|patch(options, cb), with network
$utils            ungzip only; any other helper stays absent so a bundle
                  reaching for one fails loudly rather than producing a wrong
                  result silently
$notification     post(...), recorded through the action's own console budget
                  rather than delivered, because the gateway has no channel for
                  it. It has to exist: bundles call it from their error paths.
```

`$done` receives the response projection directly rather than the native
`{response: {…}}` envelope, and `bodyBytes` and `statusCode` are accepted as
aliases for `body` and `status`. Transport hints a bundle carries on the same
object, such as `policy` or `auto-redirect`, are runtime-owned and ignored.
The first `$done` call wins.

`$response` is defined even for a request action, where it stays `undefined`
rather than absent, because the bundle assigns back to it. `$script.startTime`
exists for the same reason: the completion branch reads it before calling
`$done`, and a `TypeError` there would be swallowed by the bundle's own
`.finally()` and hang the action to its deadline instead of failing it.

An action completes when `$done` is called. A bundle that never calls it runs
until the action deadline and then fails, exactly like a native script whose
returned promise never settles.

Async is supported for both contracts: `setTimeout`, `setInterval`, and their
clear functions exist, and a native `transform` may be an `async function` or
return a promise. A timer longer than the action deadline is not shortened —
firing it early would run a bundle's own timeout branch and report a request
timeout that never happened — so the action deadline ends the action instead.
Timers are capped per action. There is still no module loader; bundles reach
their `require` calls only on a Node.js branch this runtime never selects.

## Installation and updates

**Install from URL** accepts one HTTPS manifest and snapshots its referenced
scripts. **Add locally** accepts one pasted or uploaded manifest; local
manifests use inline scripts or absolute HTTPS script URLs. Both actions install
the extension disabled.

The top-level Console Marketplace page accepts explicit HTTPS marketplace
indexes using the strict `5gpn.io/marketplace/v1` JSON contract. A marketplace
is only a bounded discovery list. The engine fetches and caches it through the
same redirect and post-resolution SSRF guard, while the Console renders only
the authenticated normalized projection. Adding or refreshing a marketplace
never installs, updates, enables, or executes an extension.

An optional source display name is local operator text only. It does not replace
the index metadata identity or prove publisher ownership. It never changes the
remote index, manifest, or script digests. The separate local normalized-source
snapshot digest includes the display name so a revision-protected write for one
reviewed label cannot authorize another.

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
leaves the new snapshot disabled. Enabling reviews capture hosts, the network
grant, every exact normalized routing rule, execution position, and the current
operator egress binding before the transaction publishes the certificate
request, in-process traffic policy, engine state, and DNS overlay.

## Telegram boundary

The monolith Telegram bot is read-only and alert-only. It may report status,
resolve a name, and send transition alerts to allowlisted administrators. It
cannot install, update, enable,
disable, reorder, configure, or remove an extension; it cannot edit catalogs,
settings, egress bindings, capture-DNS bindings, or routing rules. All extension
review and mutation stays on the authenticated Console surface.

Project-maintained examples, including Apple WLOC, live in the separate
`moooyo/5gpn-extensions` catalog. The core repository intentionally contains no
extension source. The official marketplace index is:

```text
https://moooyo.github.io/5gpn-extensions/marketplace/v2/index.json
```

The public repository also exposes Apple WLOC directly at:

```text
https://raw.githubusercontent.com/moooyo/5gpn-extensions/main/apple-wloc/extension.yaml
```
