package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

const maxInstallerMihomoConfigBytes int64 = 32 << 20

func runInterceptionRoutingCheck(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("check-interception-routing", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	mihomoPath := fs.String("mihomo-config", "", "mihomo config path")
	interceptPath := fs.String("intercept-config", "", "interception config path")
	if err := fs.Parse(args); err != nil {
		return interceptionRoutingCheckError(stdout, stderr, "arguments-invalid", fmt.Errorf("parse arguments: %w", err))
	}
	if fs.NArg() != 0 || strings.TrimSpace(*mihomoPath) == "" || strings.TrimSpace(*interceptPath) == "" {
		return interceptionRoutingCheckError(stdout, stderr, "arguments-invalid", fmt.Errorf("mihomo-config and intercept-config paths are required"))
	}

	interceptBody, err := readInstallerRoutingCheckFile(*interceptPath, int64(maxInterceptConfigBytes))
	if err != nil {
		return interceptionRoutingCheckError(stdout, stderr, "intercept-config-unreadable", fmt.Errorf("read interception config: %w", err))
	}
	document, err := decodeInterceptConfig(interceptBody)
	if err != nil {
		return interceptionRoutingCheckError(stdout, stderr, "intercept-config-invalid", err)
	}

	mihomoBody, err := readInstallerRoutingCheckFile(*mihomoPath, maxInstallerMihomoConfigBytes)
	if err != nil {
		return interceptionRoutingCheckError(stdout, stderr, "mihomo-config-unreadable", fmt.Errorf("read mihomo config: %w", err))
	}
	mihomoText := string(mihomoBody)
	mihomoDocument, err := parseMihomoNodeDocument(mihomoText)
	if err != nil {
		return interceptionRoutingCheckError(stdout, stderr, "mihomo-config-invalid", fmt.Errorf("parse mihomo config: %w", err))
	}

	analysis := analyzeInterceptRoutingDocument(mihomoText, document)
	if !analysis.Manageable || !analysis.Ready {
		reason := analysis.Reason
		if reason == "" {
			reason = "interception-routing-not-ready"
		}
		if reason == "interception-listener-missing" && len(mihomoDocument.Content) == 1 && cleanLegacyMihomoInterceptionBoundary(mihomoDocument.Content[0]) {
			reason = "legacy-mihomo-boundary-missing-clean"
		}
		fmt.Fprintln(stdout, reason)
		return 3
	}
	if !interceptCredentialsMatch(mihomoText, document) {
		fmt.Fprintln(stdout, "credential-mismatch")
		return 3
	}

	fmt.Fprintln(stdout, "ready")
	return 0
}

func cleanLegacyMihomoInterceptionBoundary(root *yaml.Node) bool {
	if sequenceContainsNamedMapping(mappingNodeValue(root, "listeners"), "intercept-egress") ||
		sequenceContainsNamedMapping(mappingNodeValue(root, "proxies"), interceptMihomoProxyName) {
		return false
	}
	rules := mappingNodeValue(root, "rules")
	if rules == nil || rules.Kind != yaml.SequenceNode {
		return false
	}
	for _, item := range rules.Content {
		if item.Kind != yaml.ScalarNode {
			return false
		}
		rule := strings.TrimSpace(item.Value)
		if rule == interceptEgressRejectRule || ruleTouchesInterceptEgress(rule) || strings.HasSuffix(compactMihomoRule(rule), ","+interceptMihomoProxyName) {
			return false
		}
	}
	return true
}

func sequenceContainsNamedMapping(sequence *yaml.Node, name string) bool {
	if sequence == nil || sequence.Kind != yaml.SequenceNode {
		return false
	}
	for _, item := range sequence.Content {
		if value, ok := mappingScalar(item, "name"); ok && value == name {
			return true
		}
	}
	return false
}

func readInstallerRoutingCheckFile(path string, limit int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	body, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > limit {
		return nil, fmt.Errorf("file exceeds %d bytes", limit)
	}
	return body, nil
}

func interceptionRoutingCheckError(stdout, stderr io.Writer, reason string, err error) int {
	fmt.Fprintln(stdout, reason)
	fmt.Fprintf(stderr, "check-interception-routing: %v\n", err)
	return 1
}
