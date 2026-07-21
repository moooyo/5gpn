package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

func runMihomoSecretPrint(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("print-mihomo-secret", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	configPath := fs.String("config", "", "mihomo config path")
	if err := fs.Parse(args); err != nil {
		return mihomoSecretPrintError(stderr, fmt.Errorf("parse arguments: %w", err))
	}
	if fs.NArg() != 0 || strings.TrimSpace(*configPath) == "" {
		return mihomoSecretPrintError(stderr, errors.New("config path is required"))
	}

	secret, err := readMihomoRootSecret(*configPath)
	if err != nil {
		return mihomoSecretPrintError(stderr, err)
	}
	if _, err := io.WriteString(stdout, secret); err != nil {
		return mihomoSecretPrintError(stderr, fmt.Errorf("write secret: %w", err))
	}
	return 0
}

func readMihomoRootSecret(path string) (string, error) {
	pathInfo, err := os.Lstat(path)
	if err != nil {
		return "", fmt.Errorf("inspect mihomo config: %w", err)
	}
	if !pathInfo.Mode().IsRegular() {
		return "", errors.New("mihomo config must be a regular file")
	}

	file, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("open mihomo config: %w", err)
	}
	defer file.Close()
	openedInfo, err := file.Stat()
	if err != nil {
		return "", fmt.Errorf("inspect opened mihomo config: %w", err)
	}
	if !openedInfo.Mode().IsRegular() || !os.SameFile(pathInfo, openedInfo) {
		return "", errors.New("mihomo config changed while it was being opened")
	}
	body, err := io.ReadAll(io.LimitReader(file, maxInstallerMihomoConfigBytes+1))
	if err != nil {
		return "", fmt.Errorf("read mihomo config: %w", err)
	}
	if int64(len(body)) > maxInstallerMihomoConfigBytes {
		return "", fmt.Errorf("mihomo config exceeds %d bytes", maxInstallerMihomoConfigBytes)
	}
	return parseMihomoRootSecret(body)
}

func parseMihomoRootSecret(body []byte) (string, error) {
	decoder := yaml.NewDecoder(bytes.NewReader(body))
	var document yaml.Node
	if err := decoder.Decode(&document); err != nil {
		if errors.Is(err, io.EOF) {
			return "", errors.New("mihomo config is empty")
		}
		return "", fmt.Errorf("parse mihomo config: %w", err)
	}
	var extra yaml.Node
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		if err != nil {
			return "", fmt.Errorf("parse mihomo config: %w", err)
		}
		return "", errors.New("multiple YAML documents are not allowed")
	}
	if len(document.Content) != 1 || document.Content[0].Kind != yaml.MappingNode {
		return "", errors.New("mihomo YAML root must be a mapping")
	}
	root := document.Content[0]
	if err := rejectDuplicateYAMLMappingKeys(root); err != nil {
		return "", err
	}

	var secret *yaml.Node
	for i := 0; i+1 < len(root.Content); i += 2 {
		key := root.Content[i]
		if key.Kind == yaml.ScalarNode && key.Tag == "!!str" && key.Value == "secret" {
			secret = root.Content[i+1]
			break
		}
	}
	if secret == nil {
		return "", errors.New("mihomo config has no root secret")
	}
	if secret.Kind != yaml.ScalarNode || secret.Tag == "!!null" {
		return "", errors.New("mihomo root secret must be a non-null scalar")
	}
	if strings.TrimSpace(secret.Value) == "" {
		return "", errors.New("mihomo root secret must not be empty")
	}
	if strings.ContainsAny(secret.Value, "\x00\r\n") {
		return "", errors.New("mihomo root secret contains unsupported control characters")
	}
	return secret.Value, nil
}

func rejectDuplicateYAMLMappingKeys(node *yaml.Node) error {
	if node == nil {
		return nil
	}
	if node.Kind == yaml.MappingNode {
		seen := make(map[string]struct{}, len(node.Content)/2)
		for i := 0; i+1 < len(node.Content); i += 2 {
			key := node.Content[i]
			if key.Kind != yaml.ScalarNode {
				return errors.New("mihomo YAML mapping keys must be scalars")
			}
			identity := key.Tag + "\x00" + key.Value
			if _, exists := seen[identity]; exists {
				return fmt.Errorf("duplicate YAML mapping key %q", key.Value)
			}
			seen[identity] = struct{}{}
			if err := rejectDuplicateYAMLMappingKeys(node.Content[i+1]); err != nil {
				return err
			}
		}
		return nil
	}
	for _, child := range node.Content {
		if err := rejectDuplicateYAMLMappingKeys(child); err != nil {
			return err
		}
	}
	return nil
}

func mihomoSecretPrintError(stderr io.Writer, err error) int {
	fmt.Fprintf(stderr, "print-mihomo-secret: %v\n", err)
	return 1
}
