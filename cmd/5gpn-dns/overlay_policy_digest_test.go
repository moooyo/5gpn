package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// Cross-implementation agreement on the typed policy projection.
//
// The marketplace publishes a policy digest computed by a JavaScript compiler
// in the extensions repository; this package compiles the same manifests in Go.
// Two implementations of one mapping drift, and they drift most quietly exactly
// where it matters — an unusual rule shape that one carries and the other
// silently drops. This test is the thing that makes such a drift loud.
//
// It runs against the real published extensions:
//
//	EXTENSIONS_REPO=/path/to/5gpn-extensions go test -run PublishedPolicy ./cmd/5gpn-dns
//
// The digests below are the ones the marketplace index carries. They are pinned
// rather than read back from a generated catalog so that a change on either side
// has to be made deliberately, in both places, by someone who looked at what
// changed about what the extension would enforce.
var publishedPolicyDigests = map[string]struct {
	directory                        string
	digest                           string
	policyRules, captureRules, total int
}{
	"io.5gpn.ad-platform-blocker": {"ad-platform-blocker",
		"a65ccac63b95fd5b8395770118ca3941dffbc17105c4ac7ec56deb996bb0a936", 201, 352, 553},
	"io.5gpn.apple-wloc": {"apple-wloc",
		"be2c9dfcdc2df0d81238dadc9bc581aa50b7218b5e1c080f91ea9466af6d88c9", 0, 4, 4},
	"io.5gpn.bilibili-cleaner": {"bilibili-cleaner",
		"a8cf8e306817244fa76361c4d3b987b79bdbe28fa1b54144a240e72048ea4f58", 5, 12, 17},
	"io.5gpn.httpdns-interceptor": {"httpdns-interceptor",
		"671a3d11b906cc87c86968cc68515f7cc61d189e92513d40c0234afa75d12fa3", 117, 128, 245},
	"io.5gpn.testflight-region-unlock": {"testflight-region-unlock",
		"f624739a7ff76cba357dd2f0ccaf716d23a04f780123872fa6970ab221dc46b7", 0, 2, 2},
	"io.5gpn.weatherkit": {"weatherkit",
		"bc83c0c1af58874296bcf3305178b2d0ffcb94961ba2a1b7917a1a9098edd66c", 1, 2, 3},
	"io.5gpn.youtube-cleaner": {"youtube-cleaner",
		"9db36c369e432ab529bcc06fffc3aa1679814a1071ee145e94eaf03636ad8653", 0, 4, 4},
	"io.5gpn.zhihu-cleaner": {"zhihu-cleaner",
		"e7d7baaa94c139160a879aad2cbbec2aabfdbc476972ba914cff84dc038030eb", 5, 10, 15},
}

// moduleFromManifest builds the policy-bearing part of a snapshot from a
// manifest on disk, using the same normalisers the importer uses. Script
// resources are deliberately not fetched: the projection is derived from
// capture hosts and routing rules alone, and requiring the network here would
// make a correctness test depend on GitHub being reachable.
func moduleFromManifest(t *testing.T, path string) interceptModuleSnapshot {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	manifest, err := decodeNativeExtensionManifest(body)
	if err != nil {
		t.Fatalf("decode %s: %v", path, err)
	}
	hosts, err := normalizeHostList(manifest.Traffic.CaptureHosts)
	if err != nil {
		t.Fatalf("%s: captureHosts: %v", path, err)
	}
	rules := make(interceptRoutingRuleList, 0, len(manifest.Traffic.RoutingRules))
	for index, raw := range manifest.Traffic.RoutingRules {
		rule, err := normalizeNativeExtensionRoutingRule(raw)
		if err != nil {
			t.Fatalf("%s: routingRules[%d]: %v", path, index, err)
		}
		rules = append(rules, rule)
	}
	return interceptModuleSnapshot{
		ID:           manifest.Metadata.ID,
		CaptureHosts: hosts,
		RoutingRules: rules,
	}
}

func TestPublishedPolicyDigestsAgreeWithTheGatewayCompiler(t *testing.T) {
	repo := os.Getenv("EXTENSIONS_REPO")
	if repo == "" {
		t.Skip("set EXTENSIONS_REPO to a 5gpn-extensions checkout to verify cross-implementation agreement")
	}
	for id, want := range publishedPolicyDigests {
		t.Run(id, func(t *testing.T) {
			module := moduleFromManifest(t, filepath.Join(repo, want.directory, "extension.yaml"))
			if module.ID != id {
				t.Fatalf("manifest declares id %q, want %q", module.ID, id)
			}
			projection, err := overlayProjectModule(module)
			if err != nil {
				t.Fatalf("compile: %v", err)
			}
			if projection.PolicyRules != want.policyRules || projection.CaptureRules != want.captureRules {
				t.Errorf("projection = %d policy + %d capture, published %d + %d",
					projection.PolicyRules, projection.CaptureRules, want.policyRules, want.captureRules)
			}
			if len(projection.Rules) != want.total {
				t.Errorf("compiled %d client rules, published %d", len(projection.Rules), want.total)
			}
			if got := overlayPolicyDigest(projection); got != want.digest {
				t.Errorf("digest mismatch\n  gateway:   %s\n  published: %s\n"+
					"the two compilers disagree about what this extension would enforce", got, want.digest)
			}
			if err := verifyOverlayPublishedPolicy(module, want.digest); err != nil {
				t.Errorf("verify: %v", err)
			}
		})
	}
}

// The catalog the gateway reads is the same file the publisher generates, so a
// digest that is present there but absent from the table above means this build
// has not been told about a newly published extension.
func TestPublishedCatalogCoversEveryPinnedExtension(t *testing.T) {
	repo := os.Getenv("EXTENSIONS_REPO")
	catalogPath := os.Getenv("EXTENSIONS_CATALOG")
	if repo == "" || catalogPath == "" {
		t.Skip("set EXTENSIONS_REPO and EXTENSIONS_CATALOG to compare against a generated marketplace index")
	}
	body, err := os.ReadFile(catalogPath)
	if err != nil {
		t.Fatalf("read catalog: %v", err)
	}
	var catalog struct {
		Entries []struct {
			ID     string `json:"id"`
			Policy struct {
				ClientRules  int    `json:"clientRules"`
				PolicyRules  int    `json:"policyRules"`
				CaptureRules int    `json:"captureRules"`
				Digest       string `json:"digest"`
			} `json:"policy"`
		} `json:"entries"`
	}
	if err := json.Unmarshal(body, &catalog); err != nil {
		t.Fatalf("decode catalog: %v", err)
	}
	if len(catalog.Entries) != len(publishedPolicyDigests) {
		t.Errorf("catalog carries %d entries, this build pins %d",
			len(catalog.Entries), len(publishedPolicyDigests))
	}
	for _, entry := range catalog.Entries {
		pinned, ok := publishedPolicyDigests[entry.ID]
		if !ok {
			t.Errorf("catalog publishes %s, which this build does not pin", entry.ID)
			continue
		}
		if entry.Policy.Digest != pinned.digest {
			t.Errorf("%s: catalog digest %s, pinned %s", entry.ID, entry.Policy.Digest, pinned.digest)
		}
		if entry.Policy.ClientRules != pinned.total {
			t.Errorf("%s: catalog reports %d client rules, pinned %d",
				entry.ID, entry.Policy.ClientRules, pinned.total)
		}
	}
}
