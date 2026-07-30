package main

import (
	"flag"
	"fmt"
	"io"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// The installer preserves an operator-owned mihomo config across upgrades, but
// the interception credentials inside it are not the operator's to own: the
// intercept config.json is the truth source that renders them in the first
// place (see render_mihomo_config in install.sh). When a run reseeds
// config.json, a preserved YAML keeps the previous pair, the routing check
// fails closed with `credential-mismatch`, and publication aborts on a host
// that is otherwise healthy.
//
// Align the two reserved blocks and nothing else. Re-serializing the document
// would reformat the whole file -- comments, quoting, key order -- so this
// rewrites the exact source lines the credential scalars sit on and leaves
// every other byte identical.
func runInterceptionCredentialAlign(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("align-interception-credentials", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	mihomoPath := fs.String("mihomo-config", "", "mihomo config path")
	interceptPath := fs.String("intercept-config", "", "interception config path")
	if err := fs.Parse(args); err != nil {
		return interceptionAlignError(stderr, fmt.Errorf("parse arguments: %w", err))
	}
	if fs.NArg() != 0 || strings.TrimSpace(*mihomoPath) == "" || strings.TrimSpace(*interceptPath) == "" {
		return interceptionAlignError(stderr, fmt.Errorf("mihomo-config and intercept-config paths are required"))
	}

	interceptBody, err := readInstallerRoutingCheckFile(*interceptPath, int64(maxInterceptConfigBytes))
	if err != nil {
		return interceptionAlignError(stderr, fmt.Errorf("read interception config: %w", err))
	}
	document, err := decodeInterceptConfig(interceptBody)
	if err != nil {
		return interceptionAlignError(stderr, err)
	}
	mihomoBody, err := readInstallerRoutingCheckFile(*mihomoPath, maxInstallerMihomoConfigBytes)
	if err != nil {
		return interceptionAlignError(stderr, fmt.Errorf("read mihomo config: %w", err))
	}
	text := string(mihomoBody)

	// Already aligned: emit the input unchanged so the caller can skip the write.
	if interceptCredentialsMatch(text, document) {
		if _, err := io.WriteString(stdout, text); err != nil {
			return interceptionAlignError(stderr, err)
		}
		return 0
	}

	aligned, err := alignInterceptCredentialLines(text, document)
	if err != nil {
		fmt.Fprintf(stderr, "align-interception-credentials: %v\n", err)
		return 3
	}
	if _, err := io.WriteString(stdout, aligned); err != nil {
		return interceptionAlignError(stderr, err)
	}
	return 0
}

type interceptCredentialTarget struct {
	node  *yaml.Node
	key   string
	value string
}

func alignInterceptCredentialLines(text string, document interceptConfigDocument) (string, error) {
	doc, err := parseMihomoNodeDocument(text)
	if err != nil || len(doc.Content) != 1 {
		return "", fmt.Errorf("mihomo config is not a single YAML document")
	}
	root := doc.Content[0]

	listener := sequenceNamedMapping(mappingNodeValue(root, "listeners"), "intercept-egress")
	if listener == nil {
		return "", fmt.Errorf("no intercept-egress listener to align")
	}
	users := mappingNodeValue(listener, "users")
	if users == nil || users.Kind != yaml.SequenceNode || len(users.Content) != 1 {
		return "", fmt.Errorf("intercept-egress listener does not carry exactly one user")
	}
	proxy := sequenceNamedMapping(mappingNodeValue(root, "proxies"), interceptMihomoProxyName)
	if proxy == nil {
		return "", fmt.Errorf("no %s proxy to align", interceptMihomoProxyName)
	}

	targets := []interceptCredentialTarget{
		{mappingScalarNode(users.Content[0], "username"), "username", document.UpstreamProxy.Username},
		{mappingScalarNode(users.Content[0], "password"), "password", document.UpstreamProxy.Password},
		{mappingScalarNode(proxy, "username"), "username", document.Username},
		{mappingScalarNode(proxy, "password"), "password", document.Password},
	}

	lines := strings.Split(text, "\n")
	for _, target := range targets {
		if target.node == nil {
			return "", fmt.Errorf("a reserved interception block is missing its %s", target.key)
		}
		if !validInterceptCredentialValue(target.value) {
			return "", fmt.Errorf("interception %s is unsafe to write into YAML", target.key)
		}
		// Only a plain scalar can be located by (line, column) and swapped in
		// place: for a quoted or block scalar the mark covers the delimiter and
		// Value does not, so the verification below would not line up anyway.
		if target.node.Style != 0 {
			return "", fmt.Errorf("interception %s is not a plain scalar", target.key)
		}
		if target.node.Line < 1 || target.node.Line > len(lines) || target.node.Column < 1 {
			return "", fmt.Errorf("interception %s has no source position", target.key)
		}
	}

	// The seed writes these blocks in flow style, so several targets share a
	// line. Apply right-to-left within a line so earlier marks stay valid.
	ordered := append([]interceptCredentialTarget(nil), targets...)
	sort.SliceStable(ordered, func(i, j int) bool {
		if ordered[i].node.Line != ordered[j].node.Line {
			return ordered[i].node.Line > ordered[j].node.Line
		}
		return ordered[i].node.Column > ordered[j].node.Column
	})
	for _, target := range ordered {
		index := target.node.Line - 1
		rewritten, err := replaceScalarAt(lines[index], target.node.Column-1, target.node.Value, target.value)
		if err != nil {
			return "", fmt.Errorf("interception %s: %w", target.key, err)
		}
		lines[index] = rewritten
	}
	return strings.Join(lines, "\n"), nil
}

// Swap the scalar that starts at `column` (0-based, in runes) for `value`,
// after proving the old text is actually there. Everything else on the line --
// indentation, flow punctuation, sibling keys, comments -- is carried through
// untouched. A mismatch means the parser's marks and this text disagree, which
// is a reason to abort, never to guess.
func replaceScalarAt(line string, column int, old, value string) (string, error) {
	runes := []rune(line)
	oldRunes := []rune(old)
	if column < 0 || column+len(oldRunes) > len(runes) {
		return "", fmt.Errorf("source position falls outside its line")
	}
	if string(runes[column:column+len(oldRunes)]) != old {
		return "", fmt.Errorf("source position does not hold the parsed value")
	}
	return string(runes[:column]) + value + string(runes[column+len(oldRunes):]), nil
}

// The installer already pins this alphabet before rendering a seed; a value
// outside it could need quoting, and quoting is exactly what this must not
// start guessing at.
func validInterceptCredentialValue(value string) bool {
	if len(value) < 16 || len(value) > 255 {
		return false
	}
	for _, r := range value {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
		case r == '.', r == '_', r == '-':
		default:
			return false
		}
	}
	return true
}

func sequenceNamedMapping(sequence *yaml.Node, name string) *yaml.Node {
	if sequence == nil || sequence.Kind != yaml.SequenceNode {
		return nil
	}
	for _, item := range sequence.Content {
		if value, ok := mappingScalar(item, "name"); ok && value == name {
			return item
		}
	}
	return nil
}

func mappingScalarNode(node *yaml.Node, key string) *yaml.Node {
	if node == nil || node.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(node.Content); i += 2 {
		if node.Content[i].Value == key && node.Content[i+1].Kind == yaml.ScalarNode {
			return node.Content[i+1]
		}
	}
	return nil
}

func interceptionAlignError(stderr io.Writer, err error) int {
	fmt.Fprintf(stderr, "align-interception-credentials: %v\n", err)
	return 1
}
