package main

import (
	"bytes"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestMihomoSecretPrintReadsExactRootString(t *testing.T) {
	tests := []struct {
		name string
		yaml string
		want string
	}{
		{
			name: "inline comment is not part of quoted secret",
			yaml: "secret: \"actual-secret\" # operator comment\n",
			want: "actual-secret",
		},
		{
			name: "quoted hash remains part of secret",
			yaml: "secret: 'actual # secret' # operator comment\n",
			want: "actual # secret",
		},
		{
			name: "only root key is selected",
			yaml: "nested:\n  secret: attacker\nsecret: controller-secret\n",
			want: "controller-secret",
		},
		{name: "numeric scalar matches mihomo", yaml: "secret: 12345\n", want: "12345"},
		{name: "leading whitespace", yaml: "secret: ' controller-secret'\n", want: " controller-secret"},
		{name: "trailing whitespace", yaml: "secret: 'controller-secret '\n", want: "controller-secret "},
		{name: "embedded quote", yaml: "secret: 'controller\"secret'\n", want: "controller\"secret"},
		{name: "embedded backslash", yaml: "secret: 'controller\\secret'\n", want: "controller\\secret"},
		{name: "embedded single quote", yaml: "secret: 'controller''secret'\n", want: "controller'secret"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			path := writeMihomoSecretTestConfig(t, []byte(test.yaml))
			var stdout bytes.Buffer
			var stderr bytes.Buffer
			code := runMihomoSecretPrint([]string{"--config", path}, &stdout, &stderr)
			if code != 0 || stdout.String() != test.want || stderr.Len() != 0 {
				t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
			}
		})
	}
}

func TestMihomoSecretPrintRejectsAmbiguousOrUnsafeInput(t *testing.T) {
	tests := []struct {
		name string
		yaml string
	}{
		{name: "duplicate root secret", yaml: "secret: first\nsecret: second\n"},
		{name: "duplicate nested key", yaml: "secret: safe\nproxy:\n  type: one\n  type: two\n"},
		{name: "multiple documents", yaml: "secret: first\n---\nsecret: second\n"},
		{name: "nested secret only", yaml: "nested:\n  secret: attacker\n"},
		{name: "alias secret", yaml: "value: &controller controller-secret\nsecret: *controller\n"},
		{name: "null secret", yaml: "secret: null\n"},
		{name: "empty secret", yaml: "secret: \"\"\n"},
		{name: "whitespace-only secret", yaml: "secret: \"  \\t\"\n"},
		{name: "multiline secret", yaml: "secret: |\n  first\n  second\n"},
		{name: "sequence root", yaml: "- secret: controller-secret\n"},
		{name: "invalid YAML", yaml: "secret: [\n"},
		{name: "empty document", yaml: ""},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			path := writeMihomoSecretTestConfig(t, []byte(test.yaml))
			var stdout bytes.Buffer
			var stderr bytes.Buffer
			code := runMihomoSecretPrint([]string{"--config", path}, &stdout, &stderr)
			if code != 1 || stdout.Len() != 0 || stderr.Len() == 0 {
				t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
			}
		})
	}
}

func TestMihomoSecretPrintRejectsOversizedAndNonRegularFiles(t *testing.T) {
	oversized := bytes.Repeat([]byte{'x'}, int(maxInstallerMihomoConfigBytes)+1)
	path := writeMihomoSecretTestConfig(t, oversized)
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	if code := runMihomoSecretPrint([]string{"--config", path}, &stdout, &stderr); code != 1 || stdout.Len() != 0 || !strings.Contains(stderr.String(), "exceeds") {
		t.Fatalf("oversized: code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}

	directory := t.TempDir()
	stdout.Reset()
	stderr.Reset()
	if code := runMihomoSecretPrint([]string{"--config", directory}, &stdout, &stderr); code != 1 || stdout.Len() != 0 || !strings.Contains(stderr.String(), "regular file") {
		t.Fatalf("directory: code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
}

func TestMihomoSecretPrintRejectsBadArgumentsAndOutputFailure(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	if code := runMihomoSecretPrint(nil, &stdout, &stderr); code != 1 || stdout.Len() != 0 || stderr.Len() == 0 {
		t.Fatalf("missing config: code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}

	path := writeMihomoSecretTestConfig(t, []byte("secret: controller-secret\n"))
	stderr.Reset()
	if code := runMihomoSecretPrint([]string{"--config", path}, failingWriter{}, &stderr); code != 1 || stderr.Len() == 0 {
		t.Fatalf("output failure: code=%d stderr=%q", code, stderr.String())
	}
}

func TestMihomoSecretPrintCLIExitContract(t *testing.T) {
	executable := filepath.Join(t.TempDir(), "5gpn-dns-secret-print")
	if runtime.GOOS == "windows" {
		executable += ".exe"
	}
	build := exec.Command("go", "build", "-o", executable, ".")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build command binary: %v: %s", err, output)
	}

	valid := writeMihomoSecretTestConfig(t, []byte("secret: \"actual-secret\" # comment\n"))
	command := exec.Command(executable, "--print-mihomo-secret", "--config", valid)
	output, err := command.CombinedOutput()
	if err != nil || string(output) != "actual-secret" {
		t.Fatalf("valid command: err=%v output=%q", err, output)
	}

	duplicate := writeMihomoSecretTestConfig(t, []byte("secret: first\nsecret: second\n"))
	command = exec.Command(executable, "--print-mihomo-secret", "--config", duplicate)
	var commandStdout bytes.Buffer
	var commandStderr bytes.Buffer
	command.Stdout = &commandStdout
	command.Stderr = &commandStderr
	err = command.Run()
	var exitError *exec.ExitError
	if !errors.As(err, &exitError) || exitError.ExitCode() != 1 || commandStdout.Len() != 0 || commandStderr.Len() == 0 {
		t.Fatalf("duplicate command: err=%v stdout=%q stderr=%q", err, commandStdout.String(), commandStderr.String())
	}
}

func writeMihomoSecretTestConfig(t *testing.T, body []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) {
	return 0, io.ErrClosedPipe
}
