package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
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
	if _, err := parseMihomoNodeDocument(mihomoText); err != nil {
		return interceptionRoutingCheckError(stdout, stderr, "mihomo-config-invalid", fmt.Errorf("parse mihomo config: %w", err))
	}

	analysis := analyzeInterceptRoutingDocument(mihomoText, document)
	if !analysis.Manageable || !analysis.Ready {
		reason := analysis.Reason
		if reason == "" {
			reason = "interception-routing-not-ready"
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
