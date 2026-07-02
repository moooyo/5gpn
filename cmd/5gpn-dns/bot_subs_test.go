package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestParseCallbackSubs(t *testing.T) {
	cases := []struct {
		data string
		kind callbackKind
		arg  string
	}{
		{"menu:subs", cbMenuSubs, ""},
		{"sub:add", cbSubAdd, ""},
		{"subview:china-ip", cbSubView, "china-ip"},
		{"subref:china-ip", cbSubRefresh, "china-ip"},
		{"subtog:china-ip", cbSubToggle, "china-ip"},
		{"subdel:china-ip", cbSubDelete, "china-ip"},
		{"subcat:adblock", cbSubCat, "adblock"},
		{"subfmt:cidr", cbSubFmt, "cidr"},
	}
	for _, c := range cases {
		got := parseCallback(c.data)
		if got.kind != c.kind || got.arg != c.arg {
			t.Errorf("parseCallback(%q) = {%v, %q}, want {%v, %q}", c.data, got.kind, got.arg, c.kind, c.arg)
		}
	}
}

func TestRenderSubs(t *testing.T) {
	views := []SubscriptionView{
		{
			Subscription: Subscription{ID: "china-ip", Category: "chnroute", Name: "china_ip_list", URL: "https://example.com/cn.txt", Format: "cidr", Enabled: true, Interval: 24 * time.Hour},
			Health:       &SubHealth{At: "2026-07-02T00:00:00Z", OK: true, Entries: 7456},
		},
		{Subscription: Subscription{ID: "ads", Category: "adblock", Name: "ad_list", Enabled: false}},
	}

	list := renderSubsList(views)
	for _, want := range []string{"china_ip_list", "7456", "ad_list", "⏸", "▶️"} {
		if !strings.Contains(list, want) {
			t.Errorf("renderSubsList missing %q:\n%s", want, list)
		}
	}

	detail := renderSubDetail(views[0])
	for _, want := range []string{"china-ip", "chnroute", "cidr", "24h", "7456", "example.com"} {
		if !strings.Contains(detail, want) {
			t.Errorf("renderSubDetail missing %q:\n%s", want, detail)
		}
	}

	if !strings.Contains(renderSubsList(nil), "暂无订阅") {
		t.Error("empty renderSubsList should say 暂无订阅")
	}
}

func TestSubAddWizardState(t *testing.T) {
	bt := &Bot{subDrafts: make(map[int64]*subDraft), pending: make(map[int64]string)}
	const chat = int64(42)

	bt.startSubAdd(chat)
	if bt.getSubDraft(chat) == nil {
		t.Fatal("startSubAdd should create a draft")
	}

	bt.subSetCategory(chat, "chnroute")
	if d := bt.getSubDraft(chat); d.category != "chnroute" {
		t.Errorf("category = %q, want chnroute", d.category)
	}

	bt.subSetFormat(chat, "cidr")
	if d := bt.getSubDraft(chat); d.format != "cidr" {
		t.Errorf("format = %q, want cidr", d.format)
	}
	if a, _ := bt.getPending(chat); a != "sub_name" {
		t.Errorf("after format, pending = %q, want sub_name", a)
	}

	bt.subSetName(chat, "my-list")
	if d := bt.getSubDraft(chat); d.name != "my-list" {
		t.Errorf("name = %q, want my-list", d.name)
	}
	if a, _ := bt.getPending(chat); a != "sub_url" {
		t.Errorf("after name, pending = %q, want sub_url", a)
	}

	bt.clearSubDraft(chat)
	if bt.getSubDraft(chat) != nil {
		t.Error("clearSubDraft should drop the draft")
	}
}

// TestBotSubReadOps exercises the read-only subscription ops against a real
// (empty) Controller/SubManager — no network fetch is triggered.
func TestBotSubReadOps(t *testing.T) {
	dir := t.TempDir()
	rulesDir := filepath.Join(dir, "rules")
	if err := os.MkdirAll(rulesDir, 0o755); err != nil {
		t.Fatal(err)
	}
	sm, err := NewSubManager(filepath.Join(dir, "subs.json"), rulesDir, func() error { return nil })
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	ctrl := NewController(sm, func() error { return nil }, rulesDir, nil, nil, nil)
	bt := &Bot{ctrl: ctrl, subDrafts: make(map[int64]*subDraft), pending: make(map[int64]string)}

	list, kb := bt.doSubsList()
	if !strings.Contains(list, "暂无订阅") {
		t.Errorf("empty doSubsList should say 暂无订阅:\n%s", list)
	}
	if kb == nil || len(kb.InlineKeyboard) < 2 {
		t.Error("subsMenu should always have add + back rows")
	}

	if _, ok := bt.findSubView("nope"); ok {
		t.Error("findSubView should miss a nonexistent id")
	}
	detail, _ := bt.doSubDetail("nope")
	if !strings.Contains(detail, "不存在") {
		t.Errorf("doSubDetail of a missing id should say 不存在:\n%s", detail)
	}
}
