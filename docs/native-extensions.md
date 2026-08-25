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

`enabled` is durable operator intent. If the root publisher has not yet
committed a valid certificate generation for that complete set, the set is
`certificate_pending`: DNS continues to claim those names at the gateway, but
the pre-capture traffic plan rejects their HTTP/TLS connections instead of
presenting an old certificate or falling through to direct routing. A matching
ready result activates the already-authorized immutable plan without another
API write or process restart. A publisher error remains fail-closed and can be
retried with a new fenced attempt.

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
Both forms reject private, loopback, link-local, CGNAT, metadata, and otherwise
unsafe addresses. An alias is resolved before rule selection; every returned
address must be globally routable, mixed public/private answers fail closed,
and the accepted address is pinned for the outbound dial while the original
hostname remains available to HTTP and TLS. Every request, including one that
reuses a pooled connection, is re-authorized against the current protected-rule
prefix and the installation-owned gateway before the extension's terminal
egress binding is applied. Every upstream connection returns through mihomo's
in-process inner dialer, carrier-scoped gateway guard, current protected prefix,
and reviewed terminal binding.

The gateway check is dynamic core state, not a static rule rendered into the
operator's mihomo YAML. It applies only to the private carrier attached to 5gpn
system and extension tunnel egress. Ordinary client ingress and generic mihomo
`INNER` traffic are not marked. DNS upstream members, subscription fetches, and
manifest importer fetches use separate direct-socket clients and retain their
own destination and redirect policies.

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

These rules are part of the complete derived interception plan. A pending or
failed interception certificate, or an unavailable fixed client boundary,
withdraws both typed `reject` and `direct` decisions. HTTP(S) hosts already
claimed for capture remain rejected before ordinary routing, while unrelated
traffic receives no extension decision. Restoring certificate and boundary
readiness restores the same typed rules without changing the interception
revision or requiring another configuration write.

Every installed extension has exactly one explicit operator egress binding.
New imports receive `DIRECT` before they are persisted; an empty or unbound
value is not representable. A manifest may declare
`requirements.egressGroup.required: true` as review metadata, but neither the
manifest nor the script can name or change the binding, and that declaration
does not alter the `DIRECT` default. The operator may select `DIRECT` or one
existing mihomo proxy group. The in-process traffic policy applies that binding
to the engine's inner dial, and the first matching extension in explicit
execution order wins. If a selected group disappears, its name remains stored
and visible and traffic fails closed until the operator chooses an available
value; there is no terminal-target or `DIRECT` fallback. A separately reviewed
`routingRules` action may still explicitly select `direct` for its own matcher.

The same execution order is used for request and response actions, top to
bottom. Every action sees the output produced by earlier actions in its phase.
Import appends an extension to the order; delete removes it; the Console can
move an extension up or down with a revision-protected, explicitly confirmed
complete reorder.

The Console exposes every declared typed setting. One save submits the complete
setting map and the engine validates and compiles it as one revision-protected
transaction; boolean, select, text, number and location values are never
published key by key. The flat `longitude`/`latitude`/optional `accuracy` trio
retains its declared scalar types while sharing the same local map editor as a
location value.

Updates may apply while an extension remains enabled. The candidate is reviewed
and refetched by digest, then replaces the immutable snapshot atomically while
preserving execution order, bindings and type-compatible operator values.
In-flight requests retain the old snapshot; later requests see the new one. A
candidate that introduces an unconfigured required value or egress requirement
is rejected before publication rather than disabling the extension implicitly.

## Operator review contract

The current `5gpn-interception` capability and operator review contract are both
version 8. The native manifest remains
`5gpn.io/v1` and the Marketplace index remains `5gpn.io/marketplace/v1`, but the
current persisted `intercept.json` document is version 7: unlike its
predecessors this revision changes what is stored, because it removed the
`catalogs` array. Installed-extension
details and install or Marketplace review candidates carry
`review_contract: 8`.

Each entry in a detail's `actions` array is a structured, bounded
`ActionReview`. Common fields state the action ID, phase, host/scheme/method/path
or status matchers, optional setting gate, action kind, body mode, timeout,
maximum body size, and `review_digest`. Script actions add their entry and source
form; scripts and JQ actions expose only a code SHA-256 and byte count, never the
source text. Mock actions expose status and headers but represent the decoded
body only by kind, byte count, and SHA-256. Header edits, URL rewrites, body
replacement declarations, rejects, and their normalized parameters remain
visible because they are the behavior the operator authorizes. Manifest bytes,
script or JQ source text, and mock body bytes never appear in this projection.

`review_digest` is deterministic over the complete executable declaration,
including matcher and gate fields, limits, declarative parameters, and digests
of hidden code or body bytes. The Console compares action IDs, digests, and
sequence to show added, removed, changed, and reordered actions. It is a review
identity, not an apply credential: candidate digest, selected Marketplace URL,
document revision, and apply-time refetch remain independently required.

The following confirmation-bearing writes require the exact value 8 and are
rejected with HTTP 400 before persistence when it is missing, stale, or future:

1. fresh URL or local install apply;
2. Marketplace update apply;
3. complete execution-order replacement; and
4. enabling an extension.

Disabling may omit `review_contract` so an operator can always revoke an
authorization. Missing, null, and zero are the same absent value for this safe
escape hatch; a nonzero stale or future version is rejected. The Console accepts
a review detail only when its returned number equals the Console's compiled-in
constant, and every protected request sends that local constant rather than
echoing the returned number. A mismatch hides the action cards, leaves confirm
unavailable, and produces no mutation request. If a stale tab nevertheless
sends its old constant after a core upgrade, the core rejects it.

Version 8 moves the persisted document with it, so there is no snapshot to carry
across the upgrade. A version 6 `intercept.json` is refused at decode — it always
carried the retired `catalogs` key — rather than migrated or read leniently.
Extensions installed under the old document are reinstalled and reviewed again
like any other; the upgrade never synthesizes a confirmation on their behalf.

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
runtime-wide time, body, header, call-count, and concurrency bounds apply; they
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
dropping the grant changes the snapshot digest, so the single Marketplace
replacement review must disclose the new grant state and its consequences.
Applying that reviewed replacement preserves the extension's prior enabled
authorization atomically; it does not require a disable-first cycle or a second
enable confirmation.

An extension holding the grant reaches the network through one unbounded egress
authorization rather than a destination allowlist. The immutable in-process
policy revalidates each request against the current document and live mihomo
group set before dialing. Every installed extension has one explicit binding,
defaulting to `DIRECT`; there is no unbound/terminal-rule fallback. A selected
group that later disappears stays visible and fails closed, including for
pooled transports after their authorization changes.

## HTTP/3 boundary

Native interception supports plain HTTP and TLS/H1/H2 only. `mitm.http3` is an
explicit capability marker whose only valid value is `false`; a management write
attempting `true` is rejected without changing the document revision. Fresh and
explicitly reset mihomo seeds contain one fixed global UDP/443 `REJECT`, and the
controller rule-management API refuses to disable it. A fallback-capable client may
retry over TCP and enter the normal capture path. An H3-only client fails.

This guard covers only UDP destination port 443 that reaches the gateway. It
does not disable ordinary UDP forwarding or QUIC sniffing on other explicitly
operator-configured ports, and it is not a host firewall.

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
accuracy visualization, and direct coordinate fields. Only an explicit Search
action posts the bounded `{query, language}` JSON body to the authenticated
same-origin `/5gpn/interception/location/search` endpoint. That server
projection contacts the fixed Nominatim origin and never forwards the
controller secret. The read-only Telegram bot does not edit extension settings
or collect locations.

The Console bundles Leaflet locally and OpenStreetMap Standard raster tiles are
the location editor's only basemap. It does not load executable map code from a
third party and does not substitute an embedded or alternate map when tiles are
unavailable. Tile requests originate in the operator's browser, retain visible
OpenStreetMap attribution, and disclose that browser's address, Console origin,
and viewed tile area to the tile service. A tile failure is a persistent editor
state; the direct coordinate fields remain usable without pretending another
map has equivalent detail.

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

An action declares exactly one of seven kinds. Five are purely declarative and
execute in the parent before worker admission:

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
  `text` or `binary`, since it edits a body it has to be given.

The remaining two kinds consume guest worker capacity:

- `jq`: one expression, at most 32768 bytes, requiring `bodyMode: text`. It does
  not instantiate JavaScript, but it runs in the isolated worker because its
  guest-controlled intermediate values can allocate memory. A document whose
  shape the expression cannot act on — a top-level array where an object was
  expected, `"data": []` standing in for an object — skips the action rather
  than failing the exchange, the same as a body that is not JSON at all;
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
result bodies remain subject to both the action limit and the runtime-wide body
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

## Worker isolation

Manifest validation and each action execute in a new one-shot mode of the same
`5gpn-mihomo` binary. This is not a persistent helper, sidecar, or second
service: the main mihomo process remains the sole long-running runtime and owns
all live configuration, storage, logs, routing, and network policy. A worker
receives only its bounded immutable input and uses bounded IPC for the narrowly
exposed storage, logging, and network operations.

The VM limits remain defense in depth, not the memory boundary. Linux workers
must enter a fresh cgroup-v2 controller subtree before untrusted code is
loaded; the installed service requires Linux 5.7 or newer, systemd 257 or newer,
and pure cgroup v2 with both memory and pids controllers.
The private namespace initially exposes the delegated unit root as
`/sys/fs/cgroup` with the trusted parent at `0::/`. Before listeners open, the
parent creates `/main` or validates a prior empty one, moves itself there,
verifies the root is empty, and enables both controllers. `DelegateSubgroup=`
remains unset because applying it before cgroup namespace creation would hide
the unit root required for worker
siblings. The normalized parent then reports `0::/main`.
Guest worker admission is global 2 and per extension 1. The per-extension bound
applies to runtime actions, while whole-document validation shares the global
pool. Admission never queues; saturation fails the current operation immediately.
Pure parent-side declarative actions do not acquire a worker slot. JQ and script
validation/execution do.

Worker admission is fixed at two concurrent processes. Every Linux leaf is
configured with
`memory.max=536870912`, `memory.swap.max=0`, `memory.oom.group=1`, and
`pids.max=32`, for admitted aggregate upper bounds of 1GiB and 64 tasks. These
are consumption caps, not reservations or a minimum-RAM check. Supported
Windows workers use a 512MiB Job Object with `ActiveProcessLimit=1`.

Worker-manager construction and the initial hard-isolation probe are mandatory
during engine construction, before any DoT, controller, or data-plane listener
opens.
Startup isolation probe failure is fatal before listeners open.
After a successful probe, each child failure stays local.
An individual child start failure, timeout, crash, or OOM therefore fails the
current operation. There is no in-process fallback on any platform.

On Linux the child must be born in its final leaf with Go `UseCgroupFD`, which
uses `clone3(CLONE_INTO_CGROUP)`. The main systemd unit therefore cannot use
`RestrictNamespaces=`: systemd 257 implements that directive by returning
`ENOSYS` for every `clone3` call. `SystemCallFilter=~unshare setns` denies the
direct namespace-switch calls without blocking `clone3`.
The runtime startup isolation probe proves the required cgroup-FD spawn.
Initial probe failure aborts monolith startup; a child is never spawned outside
the leaf and moved into it afterward. A later per-operation spawn failure is
local because the host boundary has already passed its mandatory startup probe.

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
The worker sends these calls over bounded IPC to the main process; it never
receives a socket or direct storage handle. With the network grant, a script can
make a bounded request:

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
immediately when the runtime-wide concurrency bound is saturated; an awaited
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
the extension disabled and reject an ID that is already installed. Every new
extension receives the explicit `DIRECT` egress default.

The top-level Console Marketplace page reads one index, at a URL compiled into
the core, using the strict `5gpn.io/marketplace/v1` JSON contract. A marketplace
is only a bounded discovery list. The engine fetches and caches it through the
same redirect and post-resolution SSRF guard, while the Console renders only
the authenticated normalized projection. Refreshing the marketplace
never installs, updates, enables, or executes an extension.

Only a complete successful fetch replaces the in-memory listing. A
network or parse failure, including a duplicate field or partially invalid
entry, keeps the previous complete listing regardless of cache age and displays
the fetch error beside it. An index with no successful snapshot remains empty.

There is no persisted marketplace configuration and no route that adds, renames,
removes, or disables a source. A fresh gateway contacts the built-in index the
first time an operator opens the Marketplace page, and never contacts another
one. The page labels the index from the index's own `metadata`, which is
publisher-declared discovery text and proves no more than the rest of the
listing does.

Selecting a marketplace entry refetches its manifest through this same native
parser and verifies the index's manifest SHA-256, identity, and derived
capability summary. External script resources remain live dependencies and are
not enumerated or compared against a parallel catalog resource-digest list;
their fetched bytes remain covered by the complete runtime snapshot digest. A
mismatch aborts before local state changes. A successful selection creates the
ordinary disabled immutable snapshot for a new ID, or atomically replaces an
installed snapshot while retaining its enabled authorization, typed values,
order, resolver, and egress.
Both paths still require the complete settings, permission, capture-host,
routing-rule, execution-order, and egress review described above. The
marketplace capability summary carries a required `routingRuleCount`, but the
actual normalized rules come only from the refetched manifest snapshot.
Marketplace descriptions,
tags, and licenses are informational and do not replace source review.

Installed extensions have no ordinary source-URL update check or apply route.
The operator selects the intended Marketplace entry, reviews its version,
snapshot digest, capture hosts, actions, settings, and source change, then
applies that exact refetched digest. The review response's selected-entry URL is
opaque apply state and remains distinct from a redirect-resolved manifest source.
Enabling reviews capture hosts, the network
grant, every exact normalized routing rule, execution position, and the current
operator egress binding before the transaction publishes the certificate
request, in-process traffic policy, engine state, and DNS overlay.

## Telegram boundary

The monolith Telegram bot is read-only and alert-only. It may report status,
resolve a name, and send transition alerts to allowlisted administrators. It
cannot install, update, enable,
disable, reorder, configure, or remove an extension; it cannot edit
settings, egress bindings, capture-DNS bindings, or routing rules. All extension
review and mutation stays on the authenticated Console surface.

Project-maintained extensions live in the separate
`moooyo/5gpn-extensions` catalog. The core repository intentionally contains no
extension source. That repository publishes the one index the core reads:

```text
https://moooyo.github.io/5gpn-extensions/marketplace/v2/index.json
```

Every extension in it is also reachable directly, which is what **Install from
URL** takes — the Marketplace is a way to find a manifest, not the only way to
install one:

```text
https://raw.githubusercontent.com/moooyo/5gpn-extensions/main/youtube-cleaner/extension.yaml
```
