package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestStoredInterceptRoutingRuleJSONPreservesStrictPresence(t *testing.T) {
	t.Parallel()
	valid := `{"action":"reject","domain":"ads.example.com"}`
	var rule interceptRoutingRule
	if err := json.Unmarshal([]byte(valid), &rule); err != nil {
		t.Fatal(err)
	}
	if err := validateInterceptRoutingRule(rule); err != nil {
		t.Fatal(err)
	}

	invalid := map[string]string{
		"null action":              `{"action":null,"domain":"ads.example.com"}`,
		"null domain":              `{"action":"reject","domain":null,"all_domain_keywords":["ads"]}`,
		"null domain suffix":       `{"action":"reject","domain_suffix":null,"all_domain_keywords":["ads"]}`,
		"null domain keywords":     `{"action":"reject","domain":"ads.example.com","domain_keywords":null}`,
		"null all-domain keywords": `{"action":"reject","domain":"ads.example.com","all_domain_keywords":null}`,
		"null CIDR":                `{"action":"reject","domain":"ads.example.com","ip_cidr":null}`,
		"null network":             `{"action":"reject","domain":"ads.example.com","network":null}`,
		"null destination port":    `{"action":"reject","domain":"ads.example.com","destination_port":null}`,
		"empty action":             `{"action":"","domain":"ads.example.com"}`,
		"empty domain":             `{"action":"reject","domain":"","all_domain_keywords":["ads"]}`,
		"empty domain suffix":      `{"action":"reject","domain_suffix":"","all_domain_keywords":["ads"]}`,
		"empty domain keywords":    `{"action":"reject","domain":"ads.example.com","domain_keywords":[]}`,
		"empty all keywords":       `{"action":"reject","domain":"ads.example.com","all_domain_keywords":[]}`,
		"empty CIDR":               `{"action":"reject","domain":"ads.example.com","ip_cidr":""}`,
		"empty network":            `{"action":"reject","domain":"ads.example.com","network":""}`,
		"zero destination port":    `{"action":"reject","domain":"ads.example.com","destination_port":0}`,
		"unknown field":            `{"action":"reject","domain":"ads.example.com","target":"MATCH"}`,
		"duplicate field":          `{"action":"reject","domain":"ads.example.com","domain":"other.example.com"}`,
		"case duplicate field":     `{"action":"reject","domain":"ads.example.com","Domain":"other.example.com"}`,
	}
	for name, body := range invalid {
		name, body := name, body
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			var decoded interceptRoutingRule
			if err := json.Unmarshal([]byte(body), &decoded); err == nil {
				t.Fatalf("invalid stored routing rule was accepted: %+v", decoded)
			}
		})
	}
}

func TestStoredInterceptRoutingRulesCollectionPresence(t *testing.T) {
	t.Parallel()
	module := testModuleSnapshot()
	_, omitted := testInterceptDocument(t, module)
	if _, err := decodeInterceptConfig(omitted); err != nil {
		t.Fatalf("omitted routing_rules error = %v", err)
	}

	empty := storedInterceptDocumentWithRoutingRules(t, []any{})
	document, err := decodeInterceptConfig(empty)
	if err != nil {
		t.Fatalf("empty routing_rules error = %v", err)
	}
	if len(document.Modules) != 1 || document.Modules[0].RoutingRules == nil || len(document.Modules[0].RoutingRules) != 0 {
		t.Fatalf("empty routing_rules = %#v", document.Modules[0].RoutingRules)
	}

	if _, err := decodeInterceptConfig(storedInterceptDocumentWithRoutingRules(t, nil)); err == nil || !strings.Contains(err.Error(), "routing_rules must not be null") {
		t.Fatalf("null routing_rules error = %v", err)
	}
}

func storedInterceptDocumentWithRoutingRules(t *testing.T, value any) []byte {
	t.Helper()
	_, body := testInterceptDocument(t, testModuleSnapshot())
	var document map[string]any
	if err := json.Unmarshal(body, &document); err != nil {
		t.Fatal(err)
	}
	modules, ok := document["modules"].([]any)
	if !ok || len(modules) != 1 {
		t.Fatalf("modules = %#v", document["modules"])
	}
	module, ok := modules[0].(map[string]any)
	if !ok {
		t.Fatalf("module = %#v", modules[0])
	}
	module["routing_rules"] = value
	encoded, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func TestStoredInterceptRoutingDomainsUseCanonicalCorpus(t *testing.T) {
	t.Parallel()
	cases := []struct {
		value string
		valid bool
	}{
		{value: "ads.example.com", valid: true},
		{value: "a-b.example.co.uk", valid: true},
		{value: "Ads.Example.com"},
		{value: " ads.example.com"},
		{value: "ads.example.com "},
		{value: "ads.example.com."},
		{value: "ads.example.123"},
		{value: "ads.example.c"},
		{value: "*.example.com"},
		{value: "ads_example.com"},
		{value: "ads..example.com"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(strings.ReplaceAll(tc.value, " ", "_"), func(t *testing.T) {
			t.Parallel()
			for _, rule := range []interceptRoutingRule{
				{Action: "reject", Domain: tc.value},
				{Action: "direct", DomainSuffix: tc.value},
			} {
				err := validateInterceptRoutingRule(rule)
				if (err == nil) != tc.valid {
					t.Fatalf("value %q valid=%v, error=%v", tc.value, tc.valid, err)
				}
			}
		})
	}
}

// The gateway half of the same gap the sidecar validator had: body_mode and the
// two limits were checked below two `continue`s, so five of the seven action
// kinds passed both components unchecked. Both validators have to agree, and
// they have to agree on all seven kinds -- a manifest the gateway stores and
// the sidecar then refuses wedges every later document mutation, because
// validateSidecarCandidate runs on all of them.
func TestDeclarativeActionsAreBoundsCheckedLikeScripts(t *testing.T) {
	t.Parallel()
	base := func(mutate func(*interceptScriptRule)) interceptModuleSnapshot {
		module := testModuleSnapshot()
		rule := interceptScriptRule{
			ID: "declarative", Phase: interceptPhaseResponse, BodyMode: "none",
			MaxBodyBytes: 1 << 20, TimeoutMS: 1000,
			Match: interceptActionMatch{Hosts: []string{"api.example.com"}, Schemes: []string{"https"}, PathRegex: "^/"},
			Mock:  &interceptMockResponse{Status: 200, Body: "{}"},
		}
		mutate(&rule)
		module.Scripts = []interceptScriptRule{rule}
		return module
	}
	for name, mutate := range map[string]func(*interceptScriptRule){
		"max_body_bytes below the floor":   func(r *interceptScriptRule) { r.MaxBodyBytes = -1 },
		"max_body_bytes above the ceiling": func(r *interceptScriptRule) { r.MaxBodyBytes = 1 << 30 },
		"timeout below the floor":          func(r *interceptScriptRule) { r.TimeoutMS = 5 },
		"body mode outside the enum":       func(r *interceptScriptRule) { r.BodyMode = "banana" },
		"rewrite on the response phase": func(r *interceptScriptRule) {
			r.Mock = nil
			r.Rewrite = &interceptURLRewrite{Pattern: `^https://api\.example\.com/(.*)$`, To: "https://api.example.com/v2/$1"}
		},
		"replace_body without a body": func(r *interceptScriptRule) {
			r.Mock = nil
			r.BodyMode = "none"
			r.ReplaceBody = &interceptBodyReplace{Pattern: "a", To: "b"}
		},
	} {
		t.Run(name, func(t *testing.T) {
			if err := validateInterceptModule(base(mutate)); err == nil {
				t.Fatal("accepted; the sidecar refuses this shape, and a stored document it refuses blocks every later mutation")
			}
		})
	}

	// The shape the catalog ships stays valid: the limit bounds the message an
	// action reads, and a mock reads none.
	t.Run("mock body larger than the action limit", func(t *testing.T) {
		module := base(func(r *interceptScriptRule) {
			r.MaxBodyBytes = 1024
			r.Mock = &interceptMockResponse{Status: 200, Body: strings.Repeat("x", 2048)}
		})
		if err := validateInterceptModule(module); err != nil {
			t.Fatalf("refused a manifest the catalog ships: %v", err)
		}
	})
}

// The resolver form of an upstream mapping used to skip every address check.
//
// validInterceptHostTarget returns on the "server:" prefix, so it never reached
// interceptHostTargetAddressAllowed -- the check whose own comment calls it
// "both the earliest and the only reliable place" to stop a mapping aimed at
// the gateway's management plane. What stood in for it checked only that
// parseUpstreamEntryList produced as many entries as it was given parts, and
// that parser is lenient by design: its default branch appends an entry for any
// non-empty string, so the equality held for essentially anything.
//
// Each accepted spec became a live resolver group inside the DNS daemon, dialled
// verbatim on every resolution of the mapped name. The plain UDP form is the
// strongest of the three: an arbitrary address and port, an attacker-chosen
// QNAME in the payload, and the reply parsed and returned.
func TestResolverFormHostTargetsAreScopeChecked(t *testing.T) {
	t.Parallel()
	for _, target := range []string{
		"server:127.0.0.1",
		"server:169.254.169.254", // link-local, and the cloud metadata address
		"server:10.0.0.5",
		"server:192.168.1.1",
		"server:100.64.0.1", // CGNAT, refused alongside the private ranges
		"server:ns@10.0.0.5:853",
		"server:https://a.invalid/p@127.0.0.1:8443",
		"server:not-an-ip-at-all", // a bare hostname is the self-reference footgun
		"server:",
		"server:1.1.1.1,10.0.0.1", // one bad part poisons the list
	} {
		if validInterceptHostTarget(target) {
			t.Errorf("accepted %q", target)
		}
	}
	// The form still has to work, or this is a removal rather than a fix.
	for _, target := range []string{
		"server:1.1.1.1",
		"server:8.8.8.8:53",
		"server:dns.google@8.8.8.8:853",
		"server:https://dns.google/dns-query@8.8.8.8:443",
		"server:1.1.1.1,1.0.0.1",
	} {
		if !validInterceptHostTarget(target) {
			t.Errorf("refused %q, which is an ordinary public resolver", target)
		}
	}
}

// capture_hosts must be canonical, which the error message on the sorted check
// has always claimed and only this enforces.
//
// validateInterceptHostPattern lowercases into a local and validates that,
// discarding the result, so a mixed-case host passed. It is the odd one out
// among its neighbours -- a host mapping requires pattern == normalized, an
// ip_cidr requires network.String() == rule.IPCIDR -- and it cost two
// divergences downstream: the two components' certificate host-set digests
// disagree, so every enable that changes that set burns the certificate wait
// and rolls back blaming the certificate; and the data-plane matcher stores the
// pattern verbatim while looking it up with a canonicalised request host, so
// the extension silently intercepts nothing.
func TestCaptureHostsMustBeCanonical(t *testing.T) {
	t.Parallel()
	for _, host := range []string{"API.example.com", "api.example.com.", " api.example.com", "*.EXAMPLE.com"} {
		module := testModuleSnapshot()
		module.CaptureHosts = []string{host}
		module.Scripts[0].Match.Hosts = []string{host}
		if err := validateInterceptModule(module); err == nil {
			t.Errorf("accepted non-canonical capture host %q", host)
		}
	}
	module := testModuleSnapshot()
	module.CaptureHosts = []string{"api.example.com"}
	if err := validateInterceptModule(module); err != nil {
		t.Fatalf("a canonical host was refused: %v", err)
	}
}
