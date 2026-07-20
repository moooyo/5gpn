package main

import (
	"encoding/json"
	"math"
	"strings"
	"testing"

	"github.com/go-telegram/bot/models"
)

func TestParseBotExtensionSettingText(t *testing.T) {
	minimum := 1.5
	maximum := 10.5
	tests := []struct {
		name    string
		setting interceptModuleSetting
		input   string
		want    string
		wantErr string
	}{
		{name: "text is encoded rather than interpreted", setting: interceptModuleSetting{Key: "text", Type: "text", Required: true}, input: `</code><b>&`, want: `"\u003c/code\u003e\u003cb\u003e\u0026"`},
		{name: "select", setting: interceptModuleSetting{Key: "mode", Type: "select", Options: []string{"safe", "fast"}}, input: "safe", want: `"safe"`},
		{name: "undeclared select option", setting: interceptModuleSetting{Key: "mode", Type: "select", Options: []string{"safe"}}, input: "other", wantErr: "declared option"},
		{name: "boolean true", setting: interceptModuleSetting{Key: "enabled", Type: "boolean"}, input: " true ", want: "true"},
		{name: "boolean rejects numeric shorthand", setting: interceptModuleSetting{Key: "enabled", Type: "boolean"}, input: "1", wantErr: "boolean"},
		{name: "number", setting: interceptModuleSetting{Key: "limit", Type: "number", Min: &minimum, Max: &maximum}, input: " 2.25 ", want: "2.25"},
		{name: "number below minimum", setting: interceptModuleSetting{Key: "limit", Type: "number", Min: &minimum}, input: "1", wantErr: "minimum"},
		{name: "number rejects trailing JSON", setting: interceptModuleSetting{Key: "limit", Type: "number"}, input: "2 true", wantErr: "finite number"},
		{name: "location", setting: interceptModuleSetting{Key: "point", Type: "location"}, input: " 113.9, 22.5, 25 ", want: `{"longitude":113.9,"latitude":22.5,"accuracy":25}`},
		{name: "location requires exact shape", setting: interceptModuleSetting{Key: "point", Type: "location"}, input: "113.9,22.5", wantErr: "longitude,latitude,accuracy"},
		{name: "location accuracy is integral", setting: interceptModuleSetting{Key: "point", Type: "location"}, input: "113.9,22.5,25.5", wantErr: "integer"},
		{name: "location longitude is bounded", setting: interceptModuleSetting{Key: "point", Type: "location"}, input: "181,22.5,25", wantErr: "longitude"},
		{name: "explicit values must be complete", setting: interceptModuleSetting{Key: "note", Type: "text"}, input: "  ", wantErr: "must not be empty"},
		{name: "unsupported type", setting: interceptModuleSetting{Key: "bad", Type: "object"}, input: "x", wantErr: "unsupported"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := parseBotExtensionSettingText(test.setting, test.input)
			if test.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), test.wantErr) {
					t.Fatalf("error = %v, want substring %q", err, test.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("parse setting: %v", err)
			}
			if string(got) != test.want {
				t.Fatalf("value = %s, want %s", got, test.want)
			}
		})
	}
}

func TestBotExtensionLocationValue(t *testing.T) {
	tests := []struct {
		name     string
		location models.Location
		want     string
		wantErr  string
	}{
		{name: "unknown accuracy stays conservative", location: models.Location{Longitude: 113.9, Latitude: 22.5}, want: `{"longitude":113.9,"latitude":22.5,"accuracy":100000}`},
		{name: "accuracy rounds up", location: models.Location{Longitude: -180, Latitude: 90, HorizontalAccuracy: 25.01}, want: `{"longitude":-180,"latitude":90,"accuracy":26}`},
		{name: "fraction below one rounds to one", location: models.Location{Longitude: 0, Latitude: 0, HorizontalAccuracy: 0.01}, want: `{"longitude":0,"latitude":0,"accuracy":1}`},
		{name: "negative accuracy", location: models.Location{Longitude: 0, Latitude: 0, HorizontalAccuracy: -1}, wantErr: "accuracy"},
		{name: "accuracy above maximum after rounding", location: models.Location{Longitude: 0, Latitude: 0, HorizontalAccuracy: 100000.01}, wantErr: "accuracy"},
		{name: "invalid longitude", location: models.Location{Longitude: 180.01, Latitude: 0}, wantErr: "longitude"},
		{name: "non-finite latitude", location: models.Location{Longitude: 0, Latitude: math.Inf(1)}, wantErr: "encode Telegram location"},
		{name: "non-finite accuracy", location: models.Location{Longitude: 0, Latitude: 0, HorizontalAccuracy: math.NaN()}, wantErr: "accuracy"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := botExtensionLocationValue(test.location)
			if test.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), test.wantErr) {
					t.Fatalf("error = %v, want substring %q", err, test.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("convert location: %v", err)
			}
			if string(got) != test.want {
				t.Fatalf("value = %s, want %s", got, test.want)
			}
		})
	}
}

func TestBuildBotExtensionSettings(t *testing.T) {
	settings := []interceptModuleSetting{
		{Key: "mode", Type: "select", Required: true, Options: []string{"safe", "fast"}, Value: json.RawMessage(`"safe"`)},
		{Key: "note", Type: "text", Value: json.RawMessage(`"keep"`)},
		{Key: "optional", Type: "number"},
	}

	values, err := buildBotExtensionSettings(settings, "mode", json.RawMessage(`"fast"`))
	if err != nil {
		t.Fatalf("build settings: %v", err)
	}
	if len(values) != len(settings) || string(values["mode"]) != `"fast"` || string(values["note"]) != `"keep"` {
		t.Fatalf("settings = %#v", values)
	}
	if value, ok := values["optional"]; !ok || value != nil {
		t.Fatalf("unset optional setting = %#v, present=%v", value, ok)
	}

	settings[1].Value[1] = 'X'
	if string(values["note"]) != `"keep"` {
		t.Fatalf("preserved setting aliases source: %s", values["note"])
	}

	cleared, err := buildBotExtensionSettings(settings, "optional", json.RawMessage("null"))
	if err != nil {
		t.Fatalf("clear optional setting: %v", err)
	}
	if value, ok := cleared["optional"]; !ok || value != nil {
		t.Fatalf("cleared optional setting = %#v, present=%v", value, ok)
	}

	if _, err := buildBotExtensionSettings(settings, "missing", nil); err == nil || !strings.Contains(err.Error(), "not found") {
		t.Fatalf("unknown key error = %v", err)
	}
	if _, err := buildBotExtensionSettings(settings, "mode", nil); err == nil || !strings.Contains(err.Error(), "required") {
		t.Fatalf("required unset error = %v", err)
	}
	if _, err := buildBotExtensionSettings(settings, "mode", json.RawMessage(`"unknown"`)); err == nil || !strings.Contains(err.Error(), "declared option") {
		t.Fatalf("invalid replacement error = %v", err)
	}

	duplicate := append(settings, interceptModuleSetting{Key: "note", Type: "text"})
	if _, err := buildBotExtensionSettings(duplicate, "mode", json.RawMessage(`"fast"`)); err == nil || !strings.Contains(err.Error(), "duplicate") {
		t.Fatalf("duplicate error = %v", err)
	}
}

func TestBotExtensionSettingHTMLIsSafe(t *testing.T) {
	setting := interceptModuleSetting{
		Key:   "unsafe-key",
		Type:  "text",
		Label: `<b>unsafe & label</b>`,
		Value: json.RawMessage(`"old </code><script>&"`),
	}
	valueHTML := botExtensionSettingValueHTML(setting)
	if strings.Contains(valueHTML, "<script>") || !strings.Contains(valueHTML, "&lt;script&gt;&amp;") {
		t.Fatalf("unsafe value HTML = %s", valueHTML)
	}

	confirmation := botExtensionSettingConfirmationHTML(setting, json.RawMessage(`"new <i>&"`))
	for _, unsafe := range []string{"<b>unsafe", "<script>", "<i>&"} {
		if strings.Contains(confirmation, unsafe) {
			t.Fatalf("confirmation contains unsafe input %q: %s", unsafe, confirmation)
		}
	}
	for _, escaped := range []string{"&lt;b&gt;unsafe &amp; label&lt;/b&gt;", "&lt;script&gt;&amp;", "&lt;i&gt;&amp;"} {
		if !strings.Contains(confirmation, escaped) {
			t.Fatalf("confirmation missing %q: %s", escaped, confirmation)
		}
	}

	unset := setting
	unset.Value = nil
	if got := botExtensionSettingValueHTML(unset); got != "<i>未设置</i>" {
		t.Fatalf("unset HTML = %q", got)
	}
	invalid := setting
	invalid.Value = json.RawMessage(`{"bad":true}`)
	if got := botExtensionSettingValueHTML(invalid); got != "<i>无效值</i>" {
		t.Fatalf("invalid HTML = %q", got)
	}

	location := interceptModuleSetting{Type: "location", Value: json.RawMessage(`{"longitude":113.9,"latitude":22.5,"accuracy":25}`)}
	if got := botExtensionSettingValueHTML(location); got != "<code>113.9,22.5,25</code>" {
		t.Fatalf("location HTML = %q", got)
	}
}
