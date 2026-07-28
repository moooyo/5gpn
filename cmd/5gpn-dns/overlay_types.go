package main

// Wire types for mihomo's runtime overlay control socket.
//
// These are duplicated rather than imported: cmd/5gpn-dns and the mihomo fork
// are separate modules with no shared package, and the boundary between them is
// deliberately a versioned wire format rather than a Go dependency. The schema
// version below is the compatibility check — a core advertising anything else
// is refused rather than guessed at.

const overlaySchemaVersion = 1

// overlayOwner is the owner token this control plane claims. It must match the
// `RUNTIME-OVERLAY,<owner>,…` anchors in the operator's mihomo configuration
// and the owner the core was started with.
const overlayOwner = "5gpn"

// overlayProcessorID names the single external processor 5gpn runs.
const overlayProcessorID = "intercept"

type overlayClientAction string

const (
	overlayActionDirect  overlayClientAction = "direct"
	overlayActionReject  overlayClientAction = "reject"
	overlayActionCapture overlayClientAction = "capture"
)

type overlaySelectorKind string

const (
	overlaySelectorDomain         overlaySelectorKind = "domain"
	overlaySelectorDomainSuffix   overlaySelectorKind = "domain-suffix"
	overlaySelectorDomainKeyword  overlaySelectorKind = "domain-keyword"
	overlaySelectorDomainWildcard overlaySelectorKind = "domain-wildcard"
	overlaySelectorIPCIDR         overlaySelectorKind = "ip-cidr"
	// overlaySelectorAny carries no primary selector; the keyword constraints
	// alone decide. It exists so a keyword-only reviewed rule can be expressed
	// without inventing a domain to hang it on.
	overlaySelectorAny overlaySelectorKind = "any"
)

type overlayTransitionMode string

const (
	// overlayTransitionGraceful lets already-started transactions on the
	// superseded generation finish inside a bounded drain window.
	overlayTransitionGraceful overlayTransitionMode = "graceful"
	// overlayTransitionRevoke removes the superseded generation's capabilities
	// in the same swap. Required whenever the change withdraws authority:
	// disabling an extension, removing a permission or a capture host, or
	// turning the master off.
	overlayTransitionRevoke overlayTransitionMode = "revoke"
)

type overlayPortRange struct {
	From uint16 `json:"from"`
	To   uint16 `json:"to"`
}

type overlayClientRule struct {
	Kind    overlaySelectorKind `json:"kind"`
	Value   string              `json:"value"`
	Network string              `json:"network,omitempty"`
	Ports   []overlayPortRange  `json:"ports,omitempty"`
	// KeywordsAny requires at least one to match; KeywordsAll requires all.
	// They narrow the primary selector rather than replacing it, which is the
	// shape reviewed extension rules actually use.
	KeywordsAny []string            `json:"keywordsAny,omitempty"`
	KeywordsAll []string            `json:"keywordsAll,omitempty"`
	Action      overlayClientAction `json:"action"`
	Processor   string              `json:"processor,omitempty"`
	Owner       string              `json:"owner,omitempty"`
}

type overlayDestinationRule struct {
	Kind  overlaySelectorKind `json:"kind"`
	Value string              `json:"value"`
	Ports []overlayPortRange  `json:"ports,omitempty"`
}

// overlayEgressBinding is one destination-scoped egress decision.
//
// The group hangs off the destination rather than off the credential because
// the processor authenticates with exactly one credential and its extensions
// may be bound to several groups. Minting a credential per group instead would
// hand the processor the choice of which group to leave through — the one thing
// the capability model exists to keep on the server side — and would tie the
// credential set to the operator's group list, so adding a proxy group would
// mean rewriting the configuration the overlay exists to leave alone.
type overlayEgressBinding struct {
	Group string `json:"group"`
	// Destinations is the endpoint allowlist for this group. It mirrors the
	// per-destination, per-port egress rules the legacy renderer emitted;
	// without it the binding would authorize the group for anything.
	Destinations []overlayDestinationRule `json:"destinations"`
	AllowDirect  bool                     `json:"allowDirect"`
}

type overlayEgressCapability struct {
	// ID must be exactly the credential the processor authenticates with on the
	// egress listener. A capability the processor cannot present authorizes
	// nothing, and the failure is silent: every egress dial simply rejects.
	ID string `json:"id"`
	// Listener is the inbound this capability is valid on.
	Listener string `json:"listener"`
	// Bindings is the destination-indexed egress policy, in order; the first
	// binding covering a destination decides it. The sets are disjoint by
	// construction, so order is a tie-break that should never be needed.
	Bindings        []overlayEgressBinding `json:"bindings"`
	PublicOnly      bool                   `json:"publicOnly"`
	ResolverProfile string                 `json:"resolverProfile,omitempty"`
	Owner           string                 `json:"owner,omitempty"`
}

type overlayProcessorTarget struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type overlayResolverProfile struct {
	Name        string   `json:"name"`
	Nameservers []string `json:"nameservers"`
	PreferGo    bool     `json:"preferGo,omitempty"`
}

// overlayDocument is one immutable generation of desired state.
type overlayDocument struct {
	SchemaVersion int    `json:"schemaVersion"`
	Owner         string `json:"owner"`

	GenerationID       string `json:"generationId"`
	ParentGenerationID string `json:"parentGenerationId,omitempty"`
	DocumentRevision   uint64 `json:"documentRevision"`

	Client           overlayClientStage       `json:"client"`
	Egress           overlayEgressStage       `json:"egress"`
	ProcessorTargets []overlayProcessorTarget `json:"processorTargets"`
	ResolverProfiles []overlayResolverProfile `json:"resolverProfiles,omitempty"`

	SidecarBundleDigest      string `json:"sidecarBundleDigest,omitempty"`
	CertificateHostSetDigest string `json:"certificateHostSetDigest,omitempty"`

	TransitionMode overlayTransitionMode `json:"transitionMode"`
}

type overlayClientStage struct {
	Rules []overlayClientRule `json:"rules"`
}

type overlayEgressStage struct {
	Capabilities []overlayEgressCapability `json:"capabilities"`
}

// overlayReadback is the authoritative answer to "what is actually live".
type overlayReadback struct {
	Enabled             bool     `json:"enabled"`
	ActiveGeneration    string   `json:"activeGeneration"`
	ActiveDigest        string   `json:"activeDigest"`
	ActiveProjection    string   `json:"activeProjectionDigest"`
	PersistedGeneration string   `json:"persistedGeneration"`
	CoreRevision        uint64   `json:"coreConfigRevision"`
	ResolverEpoch       uint64   `json:"resolverEpoch"`
	ProcessorState      string   `json:"processorState"`
	DependencyErrors    []string `json:"dependencyErrors"`
	ProcessorInstance   string   `json:"processorInstanceId"`
	// BundleDigest is what the last attestation claimed. ActiveBundleDigest and
	// ActiveCertHostSet are what the live generation requires — a renewal has to
	// carry those, because the core matches the lease against the document.
	BundleDigest       string   `json:"sidecarBundleDigest"`
	ActiveBundleDigest string   `json:"activeSidecarBundleDigest"`
	ActiveCertHostSet  string   `json:"activeCertificateHostSetDigest"`
	CapabilitySet      string   `json:"capabilitySetDigest"`
	LeaseState         string   `json:"leaseState"`
	LeaseExpiresAt     int64    `json:"leaseExpiresAt"`
	FencingToken       uint64   `json:"fencingToken"`
	Prepared           []string `json:"preparedGenerations"`
	Draining           []string `json:"drainingGenerations"`
	BootEpoch          string   `json:"bootEpoch"`
	SchemaVersion      int      `json:"schemaVersion"`
}

// Serviceable reports whether capture traffic can actually be processed.
func (r overlayReadback) Serviceable() bool { return r.ProcessorState == "ready" }

type overlayCommitResult struct {
	ActiveGeneration string `json:"activeGeneration"`
	ActiveDigest     string `json:"activeDigest"`
	CoreRevision     uint64 `json:"coreConfigRevision"`
	ResolverEpoch    uint64 `json:"resolverEpoch"`
	Repeated         bool   `json:"repeated"`
}

type overlayStageResult struct {
	GenerationID string `json:"generationId"`
	Digests      struct {
		Overall    string `json:"overall"`
		Projection string `json:"projection"`
	} `json:"digests"`
	ClientRules  int    `json:"clientRules"`
	Capabilities int    `json:"capabilities"`
	CoreRevision uint64 `json:"coreRevision"`
}

type overlayCapabilities struct {
	ControllerAPI string `json:"controllerApi"`
	Features      map[string]struct {
		Version int    `json:"version"`
		Owner   string `json:"owner"`
	} `json:"features"`
}

// overlayErrorBody is the stable machine-readable error the control socket
// returns. Branching on Code rather than on the message is what lets recovery
// tell "retry this operation" apart from "build a new generation".
type overlayErrorBody struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	Retryable bool   `json:"retryable"`
}
