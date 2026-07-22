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
