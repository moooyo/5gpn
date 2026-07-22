package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	telegram "github.com/go-telegram/bot"
	"github.com/go-telegram/bot/models"
)

type botExtensionTelegramCall struct {
	method string
	form   url.Values
}

type botExtensionTelegramRecorder struct {
	mu                sync.Mutex
	calls             []botExtensionTelegramCall
	sendMessageCount  int
	failSendMessageAt int
	failSendDocument  bool
}

type botExtensionRoundTripFunc func(*http.Request) (*http.Response, error)

func (fn botExtensionRoundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return fn(request)
}

func (r *botExtensionTelegramRecorder) record(method string, values url.Values) {
	clone := make(url.Values, len(values))
	for key, value := range values {
		clone[key] = append([]string(nil), value...)
	}
	r.mu.Lock()
	r.calls = append(r.calls, botExtensionTelegramCall{method: method, form: clone})
	r.mu.Unlock()
}

func (r *botExtensionTelegramRecorder) snapshot() []botExtensionTelegramCall {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]botExtensionTelegramCall(nil), r.calls...)
}

func (r *botExtensionTelegramRecorder) shouldFailSendMessage() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.sendMessageCount++
	return r.failSendMessageAt > 0 && r.sendMessageCount == r.failSendMessageAt
}

func newBotExtensionTelegramFixture(t *testing.T, ctrl *Controller) (*Bot, *botExtensionTelegramRecorder) {
	t.Helper()
	recorder := &botExtensionTelegramRecorder{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if err := request.ParseMultipartForm(16 << 20); err != nil && !errors.Is(err, io.EOF) {
			t.Errorf("parse Telegram request: %v", err)
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		method := request.URL.Path[strings.LastIndex(request.URL.Path, "/")+1:]
		values := request.Form
		if request.MultipartForm != nil {
			values = request.MultipartForm.Value
		}
		recorder.record(method, values)
		w.Header().Set("Content-Type", "application/json")
		if method == "sendMessage" && recorder.shouldFailSendMessage() {
			_, _ = w.Write([]byte(`{"ok":false,"error_code":500,"description":"injected send failure"}`))
			return
		}
		if method == "sendDocument" {
			recorder.mu.Lock()
			fail := recorder.failSendDocument
			recorder.mu.Unlock()
			if fail {
				_, _ = w.Write([]byte(`{"ok":false,"error_code":500,"description":"injected document failure"}`))
				return
			}
		}
		switch method {
		case "getMe":
			_, _ = w.Write([]byte(`{"ok":true,"result":{"id":123,"is_bot":true,"first_name":"5gpn","username":"fivegpn_bot"}}`))
		case "getWebhookInfo":
			_, _ = w.Write([]byte(`{"ok":true,"result":{"url":"","has_custom_certificate":false,"pending_update_count":0}}`))
		case "sendMessage", "editMessageText", "sendLocation", "sendDocument":
			_, _ = w.Write([]byte(`{"ok":true,"result":{"message_id":1,"date":1,"chat":{"id":111,"type":"private"}}}`))
		default:
			t.Errorf("unexpected Telegram method %q", method)
			http.Error(w, "unexpected", http.StatusNotFound)
		}
	}))
	t.Cleanup(server.Close)
	bt, err := newBotWithOptions(Config{
		TGBotToken:  "123:test-token",
		TGBotAdmins: map[int64]bool{111: true, 222: true},
	}, ctrl, telegram.WithServerURL(server.URL), telegram.WithNotAsyncHandlers())
	if err != nil {
		t.Fatal(err)
	}
	return bt, recorder
}

func botExtensionTestCallback() *models.CallbackQuery {
	return &models.CallbackQuery{
		ID:   "callback-id",
		From: models.User{ID: 111},
		Message: models.MaybeInaccessibleMessage{
			Type: models.MaybeInaccessibleMessageTypeMessage,
			Message: &models.Message{
				ID: 9, Chat: models.Chat{ID: 111, Type: models.ChatTypePrivate},
			},
		},
	}
}

func botExtensionTestOperation(t *testing.T, bt *Bot) context.Context {
	t.Helper()
	owner, generation, err := bt.extensionStateStore().BeginOperation(111, 111)
	if err != nil {
		t.Fatal(err)
	}
	return withBotExtensionOperation(context.Background(), owner, generation)
}

func botExtensionOnlyConfirmation(t *testing.T, store *botExtensionStateStore) (string, botExtensionStatePayload) {
	t.Helper()
	store.mu.Lock()
	defer store.mu.Unlock()
	var token string
	var payload botExtensionStatePayload
	for candidate, entry := range store.tokens {
		if entry.purpose != botExtensionTokenConfirmation {
			continue
		}
		if token != "" {
			t.Fatal("more than one extension confirmation was issued")
		}
		token = candidate
		payload = cloneBotExtensionPayload(entry.payload)
	}
	if token == "" {
		t.Fatal("no extension confirmation was issued")
	}
	return token, payload
}

func botExtensionSelectionToken(
	t *testing.T,
	store *botExtensionStateStore,
	kind botExtensionPayloadKind,
	stringValue string,
) string {
	t.Helper()
	store.mu.Lock()
	defer store.mu.Unlock()
	var token string
	for candidate, entry := range store.tokens {
		if entry.purpose != botExtensionTokenSelection || entry.payload.Kind != kind || entry.payload.StringValue != stringValue {
			continue
		}
		if token != "" {
			t.Fatalf("more than one %s selection was issued for %q", kind, stringValue)
		}
		token = candidate
	}
	if token == "" {
		t.Fatalf("no %s selection was issued for %q", kind, stringValue)
	}
	return token
}

func TestBotExtensionCallbackDataStaysWithinTelegramLimit(t *testing.T) {
	token := strings.Repeat("A", 16)
	for _, action := range []string{
		"source:" + token + ":10000",
		"source:refresh:" + token,
		"entry:install:" + token,
		"module:toggle:" + token,
		"settings:" + token + ":10000",
		"setting:value:" + token,
		"egress:set:" + token,
		"capture-dns:set:" + token,
	} {
		if data := botExtensionCallbackData(action); len(data) > 64 {
			t.Fatalf("callback_data %q has %d bytes", data, len(data))
		}
	}
	for _, kind := range []botExtensionPayloadKind{
		botExtensionPayloadMarketplaceAdd,
		botExtensionPayloadMarketplaceDelete,
		botExtensionPayloadMarketplaceRefresh,
		botExtensionPayloadInstall,
		botExtensionPayloadUninstall,
		botExtensionPayloadEnable,
		botExtensionPayloadDisable,
		botExtensionPayloadUpdate,
		botExtensionPayloadSetting,
		botExtensionPayloadEgress,
		botExtensionPayloadCaptureDNS,
		botExtensionPayloadReorder,
		botExtensionPayloadMITM,
	} {
		keyboard := botExtensionConfirmationMenu(kind, token)
		for _, row := range keyboard.InlineKeyboard {
			for _, button := range row {
				if len(button.CallbackData) > 64 {
					t.Fatalf("callback_data %q has %d bytes", button.CallbackData, len(button.CallbackData))
				}
				if strings.Contains(button.CallbackData, "io.example") || strings.Contains(button.CallbackData, "https://") {
					t.Fatalf("callback_data leaked dynamic identity: %q", button.CallbackData)
				}
			}
		}
	}
}

func TestBotExtensionIncompleteReviewNeverIssuesConfirmation(t *testing.T) {
	ctrl := NewController(func() error { return nil }, nil, nil, nil)
	bt, recorder := newBotExtensionTelegramFixture(t, ctrl)
	recorder.mu.Lock()
	recorder.failSendMessageAt = 2
	recorder.mu.Unlock()
	payload := botExtensionStatePayload{
		Kind: botExtensionPayloadEnable, Revision: strings.Repeat("a", 64),
		ModuleID: "io.example.fixture", Digest: strings.Repeat("b", 64), BoolValue: true,
	}
	review := "<b>完整审查</b>\n" + strings.Repeat("safe-content ", 700)
	bt.issueBotExtensionConfirmation(botExtensionTestOperation(t, bt), bt.tg, botExtensionTestCallback(), 111, 111, payload, review)
	store := bt.extensionStateStore()
	store.mu.Lock()
	defer store.mu.Unlock()
	for _, entry := range store.tokens {
		if entry.purpose == botExtensionTokenConfirmation {
			t.Fatal("confirmation was issued after a review chunk failed")
		}
	}
}

func TestBotExtensionLongReviewUsesProtectedDocumentBeforeConfirmation(t *testing.T) {
	ctrl := NewController(func() error { return nil }, nil, nil, nil)
	bt, recorder := newBotExtensionTelegramFixture(t, ctrl)
	payload := botExtensionStatePayload{
		Kind: botExtensionPayloadEnable, Revision: strings.Repeat("a", 64),
		ModuleID: "io.example.fixture", Digest: strings.Repeat("b", 64), BoolValue: true,
	}
	review := "<b>完整审查</b>\n" + strings.Repeat("逐项安全内容 ", 5000)
	bt.issueBotExtensionConfirmation(botExtensionTestOperation(t, bt), bt.tg, botExtensionTestCallback(), 111, 111, payload, review)
	documentIndex := -1
	confirmIndex := -1
	for index, call := range recorder.snapshot() {
		if call.method == "sendDocument" {
			documentIndex = index
			if call.form.Get("protect_content") != "true" {
				t.Fatalf("long review document was not protected: %v", call.form)
			}
		}
		if call.method == "sendMessage" && strings.Contains(call.form.Get("reply_markup"), "confirm:enable") {
			confirmIndex = index
		}
	}
	if documentIndex < 0 || confirmIndex <= documentIndex {
		t.Fatalf("document/confirmation order = %d/%d", documentIndex, confirmIndex)
	}
	botExtensionOnlyConfirmation(t, bt.extensionStateStore())
}

func TestBotExtensionFailedReviewDocumentNeverIssuesConfirmation(t *testing.T) {
	ctrl := NewController(func() error { return nil }, nil, nil, nil)
	bt, recorder := newBotExtensionTelegramFixture(t, ctrl)
	recorder.mu.Lock()
	recorder.failSendDocument = true
	recorder.mu.Unlock()
	payload := botExtensionStatePayload{
		Kind: botExtensionPayloadEnable, Revision: strings.Repeat("a", 64),
		ModuleID: "io.example.fixture", Digest: strings.Repeat("b", 64), BoolValue: true,
	}
	review := "<b>完整审查</b>\n" + strings.Repeat("逐项安全内容 ", 5000)
	bt.issueBotExtensionConfirmation(botExtensionTestOperation(t, bt), bt.tg, botExtensionTestCallback(), 111, 111, payload, review)
	bt.extensionStateStore().mu.Lock()
	defer bt.extensionStateStore().mu.Unlock()
	for _, entry := range bt.extensionStateStore().tokens {
		if entry.purpose == botExtensionTokenConfirmation {
			t.Fatal("confirmation was issued after the protected review document failed")
		}
	}
}

func TestBotExtensionNetworkEnableReviewListsEveryOrigin(t *testing.T) {
	module := testModuleSnapshot()
	module.NetworkOrigins = []string{"https://audit.example.com", "https://upload.example.net:8443"}
	module.RoutingRules = []interceptRoutingRule{{Action: "reject", Domain: "ads.example.com", Network: "udp"}}
	manager, _, _, _, _ := newInterceptManagerFixture(t, module)
	ctrl := NewController(func() error { return nil }, nil, nil, nil)
	ctrl.SetInterceptModuleManager(manager)
	bt, recorder := newBotExtensionTelegramFixture(t, ctrl)
	view, err := ctrl.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	token, _, err := bt.extensionStateStore().IssueSelection(111, 111, botExtensionStatePayload{
		Kind: botExtensionPayloadModule, Revision: view.Revision,
		ModuleID: module.ID, Digest: view.Modules[0].SnapshotDigest,
	})
	if err != nil {
		t.Fatal(err)
	}
	bt.previewBotExtensionToggle(botExtensionTestOperation(t, bt), bt.tg, botExtensionTestCallback(), 111, 111, token)
	var delivered strings.Builder
	for _, call := range recorder.snapshot() {
		if call.method == "sendMessage" {
			delivered.WriteString(call.form.Get("text"))
		}
	}
	text := delivered.String()
	for _, want := range []string{
		"https://audit.example.com",
		"https://upload.example.net:8443",
		"解密请求、响应、参数和存储数据",
		"完整请求方法、解码后的请求体和端到端请求头",
		"Cookie 和 Authorization 凭据",
		"clean-response",
		view.Modules[0].Actions[0].ScriptDigest,
		"Global routing rules",
		`{&#34;action&#34;:&#34;reject&#34;,&#34;domain&#34;:&#34;ads.example.com&#34;,&#34;network&#34;:&#34;udp&#34;}`,
		"Capture DNS",
		"<code>Trust</code>",
		"第一个 enabled 插件",
		"实时 China group",
		"当前 ECS",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("network risk review omitted %q:\n%s", want, text)
		}
	}
	_, payload := botExtensionOnlyConfirmation(t, bt.extensionStateStore())
	if payload.Kind != botExtensionPayloadEnable || payload.Digest != view.Modules[0].SnapshotDigest {
		t.Fatalf("enable confirmation payload = %+v", payload)
	}
}

func TestBotExtensionCaptureDNSReviewIsOneUseAndAppliesMutableBinding(t *testing.T) {
	module := testModuleSnapshot()
	manager, _, _, _, _ := newInterceptManagerFixture(t, module)
	ctrl := NewController(func() error { return nil }, nil, nil, nil)
	ctrl.SetInterceptModuleManager(manager)
	bt, recorder := newBotExtensionTelegramFixture(t, ctrl)
	view, err := ctrl.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	beforeDigest := view.Modules[0].SnapshotDigest
	moduleToken, _, err := bt.extensionStateStore().IssueSelection(111, 111, botExtensionStatePayload{
		Kind: botExtensionPayloadModule, Revision: view.Revision,
		ModuleID: module.ID, Digest: beforeDigest,
	})
	if err != nil {
		t.Fatal(err)
	}
	opCtx := botExtensionTestOperation(t, bt)
	bt.renderBotExtensionModule(opCtx, bt.tg, botExtensionTestCallback(), 111, moduleToken, "")
	bt.handleExtensionCallback(context.Background(), bt.tg, botExtensionTestCallback(), 111, 111, "capture-dns:"+moduleToken)
	chinaToken := botExtensionSelectionToken(t, bt.extensionStateStore(), botExtensionPayloadCaptureDNS, interceptCaptureDNSChina)
	bt.handleExtensionCallback(context.Background(), bt.tg, botExtensionTestCallback(), 111, 111, "capture-dns:set:"+chinaToken)

	var delivered strings.Builder
	var markup strings.Builder
	for _, call := range recorder.snapshot() {
		delivered.WriteString(call.form.Get("text"))
		markup.WriteString(call.form.Get("reply_markup"))
	}
	for _, required := range []string{
		"Capture DNS", "capture host", "Action metadata", beforeDigest, view.Revision,
		"当前绑定：<code>Trust</code>", "新绑定：<code>China</code>",
		"实时 China group", "当前 ECS", "mihomo loopback origin re-resolution",
		"不改变客户端 DNS policy", "第一个插件是 DNS 绑定赢家",
	} {
		if !strings.Contains(delivered.String(), required) {
			t.Fatalf("Capture DNS review omitted %q: %s", required, delivered.String())
		}
	}
	if !strings.Contains(markup.String(), "capture-dns:") || !strings.Contains(markup.String(), "capture-dns:set:") {
		t.Fatalf("Capture DNS detail/menu buttons missing: %s", markup.String())
	}

	confirmationToken, confirmation := botExtensionOnlyConfirmation(t, bt.extensionStateStore())
	if confirmation.Kind != botExtensionPayloadCaptureDNS || confirmation.Revision != view.Revision ||
		confirmation.ModuleID != module.ID || confirmation.Digest != beforeDigest || confirmation.StringValue != interceptCaptureDNSChina {
		t.Fatalf("Capture DNS confirmation payload = %+v", confirmation)
	}
	confirmed, ok := bt.extensionStateStore().ConsumeConfirmation(
		confirmationToken, 111, 111, botExtensionPayloadCaptureDNS,
	)
	if !ok {
		t.Fatal("Capture DNS confirmation could not be consumed")
	}
	if _, reused := bt.extensionStateStore().ConsumeConfirmation(
		confirmationToken, 111, 111, botExtensionPayloadCaptureDNS,
	); reused {
		t.Fatal("Capture DNS confirmation was reusable")
	}
	if err := bt.applyBotExtensionConfirmation(context.Background(), confirmed); err != nil {
		t.Fatal(err)
	}
	after, err := ctrl.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	if after.Revision == view.Revision || after.Modules[0].CaptureDNS != interceptCaptureDNSChina {
		t.Fatalf("Capture DNS apply result = revision %q module %+v", after.Revision, after.Modules[0])
	}
	if after.Modules[0].SnapshotDigest != beforeDigest {
		t.Fatalf("mutable Capture DNS changed snapshot digest: %q -> %q", beforeDigest, after.Modules[0].SnapshotDigest)
	}
}

func TestBotExtensionCaptureDNSConfirmationRejectsStaleRevisionAndSnapshot(t *testing.T) {
	module := testModuleSnapshot()
	manager, _, _, _, _ := newInterceptManagerFixture(t, module)
	ctrl := NewController(func() error { return nil }, nil, nil, nil)
	ctrl.SetInterceptModuleManager(manager)
	bt := &Bot{ctrl: ctrl}
	before, err := ctrl.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	payload := botExtensionStatePayload{
		Kind: botExtensionPayloadCaptureDNS, Revision: before.Revision,
		ModuleID: module.ID, Digest: before.Modules[0].SnapshotDigest, StringValue: interceptCaptureDNSChina,
	}
	china := interceptCaptureDNSChina
	changed, err := ctrl.UpdateInterceptModule(context.Background(), module.ID, interceptModuleUpdate{
		Revision: before.Revision, CaptureDNS: &china,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := bt.applyBotExtensionConfirmation(context.Background(), payload); !errors.Is(err, errInterceptRevisionConflict) {
		t.Fatalf("stale Capture DNS revision error = %v", err)
	}
	payload.Revision = changed.Revision
	payload.Digest = strings.Repeat("f", 64)
	payload.StringValue = interceptCaptureDNSTrust
	if err := bt.applyBotExtensionConfirmation(context.Background(), payload); err == nil || !strings.Contains(err.Error(), "snapshot") {
		t.Fatalf("stale Capture DNS snapshot error = %v", err)
	}
	payload.Digest = changed.Modules[0].SnapshotDigest
	payload.StringValue = "automatic"
	if err := bt.applyBotExtensionConfirmation(context.Background(), payload); err == nil || !strings.Contains(err.Error(), "capture_dns") {
		t.Fatalf("invalid Capture DNS confirmation error = %v", err)
	}
	current, err := ctrl.InterceptModules()
	if err != nil || current.Modules[0].CaptureDNS != interceptCaptureDNSChina {
		t.Fatalf("stale confirmation mutated Capture DNS: view=%+v err=%v", current, err)
	}
}

func TestBotExtensionReorderReviewShowsCaptureDNSWinnerSemantics(t *testing.T) {
	first := testModuleSnapshot()
	first.Enabled = true
	first.Name = "Trust first"
	second := testModuleSnapshot()
	second.ID = "io.example.second"
	second.Name = "China second"
	second.Enabled = true
	second.CaptureDNS = interceptCaptureDNSChina
	manager, _, _, _, _ := newInterceptManagerFixture(t, first, second)
	ctrl := NewController(func() error { return nil }, nil, nil, nil)
	ctrl.SetInterceptModuleManager(manager)
	bt, recorder := newBotExtensionTelegramFixture(t, ctrl)
	view, err := ctrl.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	token, _, err := bt.extensionStateStore().IssueSelection(111, 111, botExtensionStatePayload{
		Kind: botExtensionPayloadModule, Revision: view.Revision,
		ModuleID: second.ID, Digest: view.Modules[1].SnapshotDigest,
	})
	if err != nil {
		t.Fatal(err)
	}
	bt.previewBotExtensionReorder(botExtensionTestOperation(t, bt), bt.tg, botExtensionTestCallback(), 111, 111, token, "up")
	var delivered strings.Builder
	for _, call := range recorder.snapshot() {
		delivered.WriteString(call.form.Get("text"))
	}
	text := delivered.String()
	for _, required := range []string{
		"完整旧顺序", "完整新顺序", "capture_dns=<code>Trust</code>", "capture_dns=<code>China</code>",
		"第一个 enabled mihomo origin re-resolution DNS 绑定赢家", "实时 China group", "当前 ECS",
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("reorder review omitted %q: %s", required, text)
		}
	}
	_, payload := botExtensionOnlyConfirmation(t, bt.extensionStateStore())
	if payload.Kind != botExtensionPayloadReorder || payload.Revision != view.Revision || payload.Digest != view.Modules[1].SnapshotDigest {
		t.Fatalf("reorder confirmation payload = %+v", payload)
	}
}

func TestMarketplaceSourceReviewRendersEveryEntryAndNetworkOrigin(t *testing.T) {
	source := marketplaceSourceView{
		ID: "io.example.marketplace", MetadataName: "Example marketplace", Description: "Catalog description",
		Homepage: "https://catalog.example/", URL: "https://catalog.example/index.json", FinalURL: "https://cdn.example/index.json",
		Digest: strings.Repeat("a", 64), SnapshotDigest: strings.Repeat("b", 64),
		Entries: []marketplaceEntryView{
			{
				ID: "io.example.one", Name: "Extension one", Version: "1.2.3", Description: "First extension",
				License: marketplaceLicense{SPDX: "MIT"}, ManifestURL: "https://catalog.example/one.yaml", ManifestDigest: strings.Repeat("c", 64),
				Capabilities: marketplaceCapabilitiesView{CaptureHostCount: 2, ActionCount: 3, SettingCount: 4, UpstreamMappingCount: 5, RoutingRuleCount: 6,
					NetworkOrigins: []string{"https://audit.example.com", "https://upload.example.net:8443"}, PersistentStorage: true, EgressGroupRequired: true},
			},
			{
				ID: "io.example.two", Name: "Extension two", Version: "2.0.0", Description: "Second extension",
				License: marketplaceLicense{SPDX: "Apache-2.0"}, ManifestURL: "https://catalog.example/two.yaml", ManifestDigest: strings.Repeat("d", 64),
			},
		},
	}
	review := marketplaceSourceReviewHTML(source)
	for _, required := range []string{
		"io.example.one", "1.2.3", strings.Repeat("c", 64), "https://audit.example.com", "https://upload.example.net:8443",
		"io.example.two", "2.0.0", strings.Repeat("d", 64), "<code>6</code> global routing rules", "storage=<code>true</code>", "egress-required=<code>true</code>",
	} {
		if !strings.Contains(review, required) {
			t.Fatalf("marketplace source review omitted %q: %s", required, review)
		}
	}
}

func TestBotExtensionProtocolReviewsListEveryArmedNetworkOrigin(t *testing.T) {
	module := testModuleSnapshot()
	module.Enabled = true
	module.NetworkOrigins = []string{"https://audit.example.com", "https://upload.example.net:8443"}
	manager, _, _, _, _ := newInterceptManagerFixture(t, module)
	ctrl := NewController(func() error { return nil }, nil, nil, nil)
	ctrl.SetInterceptModuleManager(manager)
	bt := &Bot{ctrl: ctrl}
	settings, err := ctrl.InterceptSettings()
	if err != nil {
		t.Fatal(err)
	}
	next := interceptMITMSettings{Enabled: settings.Enabled, HTTP2: !settings.HTTP2, QUICFallbackProtection: !settings.QUICFallbackProtection}
	for _, field := range []string{"http2", "quic"} {
		review, reviewErr := bt.botExtensionMITMReview(settings.Revision, field, next)
		if reviewErr != nil {
			t.Fatalf("%s review: %v", field, reviewErr)
		}
		for _, origin := range module.NetworkOrigins {
			if !strings.Contains(review, origin) {
				t.Fatalf("%s review omitted network origin %q: %s", field, origin, review)
			}
		}
		if !strings.Contains(review, "解密请求、响应、参数和存储数据") ||
			!strings.Contains(review, "Cookie 和 Authorization 凭据") {
			t.Fatalf("%s review omitted explicit network exfiltration warning: %s", field, review)
		}
	}
}

func TestBotExtensionMarketplaceInstallBindsBothRevisionsAndDigests(t *testing.T) {
	ctx := context.Background()
	fixture := newMarketplaceFixture(t, nil)
	marketplaces, modules, _ := newMarketplaceManagerFixture(t, fixture)
	ctrl := NewController(func() error { return nil }, nil, nil, nil)
	ctrl.SetInterceptModuleManager(modules)
	ctrl.SetExtensionMarketplaceManager(marketplaces)
	market, err := ctrl.ExtensionMarketplaces()
	if err != nil {
		t.Fatal(err)
	}
	market, err = ctrl.AddExtensionMarketplace(ctx, market.Revision, fixture.server.URL+"/index.json", "")
	if err != nil {
		t.Fatal(err)
	}
	moduleView, err := ctrl.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	source := market.Sources[0]
	entry := source.Entries[0]
	bt, _ := newBotExtensionTelegramFixture(t, ctrl)
	raw, _ := marshalBotExtensionMutation(botExtensionMutation{
		SourceDigest: source.SnapshotDigest, ManifestDigest: entry.ManifestDigest,
	})
	selection, _, err := bt.extensionStateStore().IssueSelection(111, 111, botExtensionStatePayload{
		Kind: botExtensionPayloadMarketplaceEntry, Revision: market.Revision,
		SourceID: source.ID, EntryID: entry.ID, Digest: entry.ManifestDigest, RawJSON: raw,
	})
	if err != nil {
		t.Fatal(err)
	}
	bt.previewBotExtensionMarketplaceInstall(botExtensionTestOperation(t, bt), bt.tg, botExtensionTestCallback(), 111, 111, selection)
	_, payload := botExtensionOnlyConfirmation(t, bt.extensionStateStore())
	if payload.Revision != market.Revision || payload.ModuleRevision != moduleView.Revision {
		t.Fatalf("market/module revisions = %q/%q, want %q/%q", payload.Revision, payload.ModuleRevision, market.Revision, moduleView.Revision)
	}
	if payload.Digest != source.SnapshotDigest || !validSHA256(payload.CandidateDigest) {
		t.Fatalf("source/candidate proofs = %q/%q", payload.Digest, payload.CandidateDigest)
	}
	if payload.ModuleID != entry.ID {
		t.Fatalf("candidate module id = %q, want %q", payload.ModuleID, entry.ID)
	}
	if err := bt.applyBotExtensionConfirmation(ctx, payload); err != nil {
		t.Fatalf("apply marketplace confirmation: %v", err)
	}
	installed, err := ctrl.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	if len(installed.Modules) != 1 || installed.Modules[0].Enabled {
		t.Fatalf("marketplace install did not remain disabled: %+v", installed.Modules)
	}
}

func TestBotExtensionLocationInputPreviewsAndConfirmsCompleteSettings(t *testing.T) {
	module := testModuleSnapshot()
	module.Settings = []interceptModuleSetting{
		{Key: "enabled", Type: "boolean", Value: json.RawMessage("true")},
		{Key: "target", Type: "location", Required: true},
	}
	manager, _, _, _, _ := newInterceptManagerFixture(t, module)
	ctrl := NewController(func() error { return nil }, nil, nil, nil)
	ctrl.SetInterceptModuleManager(manager)
	bt, recorder := newBotExtensionTelegramFixture(t, ctrl)
	view, err := ctrl.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	payload := botExtensionStatePayload{
		Kind: botExtensionPayloadSetting, Revision: view.Revision,
		ModuleID: module.ID, SettingKey: "target", Digest: view.Modules[0].SnapshotDigest,
	}
	if _, err := bt.extensionStateStore().BeginInput(111, 111, botExtensionInputSettingLocation, payload); err != nil {
		t.Fatal(err)
	}
	update := &models.Update{Message: &models.Message{
		From: &models.User{ID: 111},
		Chat: models.Chat{ID: 111, Type: models.ChatTypePrivate},
		Location: &models.Location{
			Longitude: 121.4737, Latitude: 31.2304, HorizontalAccuracy: 18.2,
		},
	}}
	if !bt.handleExtensionInput(context.Background(), bt.tg, update, 111) {
		t.Fatal("location input was not consumed")
	}
	calls := recorder.snapshot()
	locationIndex := -1
	confirmIndex := -1
	for index, call := range calls {
		switch call.method {
		case "sendLocation":
			locationIndex = index
			if call.form.Get("longitude") != "121.4737" || call.form.Get("latitude") != "31.2304" || call.form.Get("protect_content") != "true" {
				t.Fatalf("location preview form = %v", call.form)
			}
		case "sendMessage":
			if strings.Contains(call.form.Get("reply_markup"), "confirm:setting") {
				confirmIndex = index
			}
		}
	}
	if locationIndex < 0 || confirmIndex < 0 || locationIndex >= confirmIndex {
		t.Fatalf("location/confirmation delivery order = %d/%d, calls=%+v", locationIndex, confirmIndex, calls)
	}
	_, confirmation := botExtensionOnlyConfirmation(t, bt.extensionStateStore())
	mutation, err := decodeBotExtensionMutation(confirmation.RawJSON)
	if err != nil {
		t.Fatal(err)
	}
	if len(mutation.Settings) != 2 || string(mutation.Settings["enabled"]) != "true" || len(mutation.Settings["target"]) == 0 {
		t.Fatalf("complete settings map = %s", confirmation.RawJSON)
	}
	var delivered strings.Builder
	for _, call := range calls {
		if call.method == "sendMessage" {
			delivered.WriteString(call.form.Get("text"))
		}
	}
	if !strings.Contains(delivered.String(), "Telegram Bot API") {
		t.Fatalf("location review omitted Telegram Bot API warning: %s", delivered.String())
	}
	if err := bt.applyBotExtensionConfirmation(context.Background(), confirmation); err != nil {
		t.Fatal(err)
	}
	after, err := ctrl.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	if len(after.Modules) != 1 || len(after.Modules[0].Settings) != 2 || string(after.Modules[0].Settings[0].Value) != "true" {
		t.Fatalf("location apply did not preserve complete settings: %+v", after.Modules)
	}
	var stored interceptLocationValue
	if err := json.Unmarshal(after.Modules[0].Settings[1].Value, &stored); err != nil || stored.Longitude == nil || stored.Latitude == nil || *stored.Longitude != 121.4737 || *stored.Latitude != 31.2304 || stored.Accuracy != 19 {
		t.Fatalf("stored location = %+v err=%v", stored, err)
	}
}

func TestBotExtensionTextSettingAcceptsSlashPrefixedValue(t *testing.T) {
	module := testModuleSnapshot()
	module.Settings = []interceptModuleSetting{{Key: "path", Type: "text", Required: true, Value: json.RawMessage(`"/old"`)}}
	manager, _, _, _, _ := newInterceptManagerFixture(t, module)
	ctrl := NewController(func() error { return nil }, nil, nil, nil)
	ctrl.SetInterceptModuleManager(manager)
	bt, _ := newBotExtensionTelegramFixture(t, ctrl)
	view, err := ctrl.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	payload := botExtensionStatePayload{
		Kind: botExtensionPayloadSetting, Revision: view.Revision,
		ModuleID: module.ID, SettingKey: "path", Digest: view.Modules[0].SnapshotDigest,
	}
	if _, err := bt.extensionStateStore().BeginInput(111, 111, botExtensionInputSettingText, payload); err != nil {
		t.Fatal(err)
	}
	bt.defaultHandler(context.Background(), bt.tg, &models.Update{Message: &models.Message{
		From: &models.User{ID: 111}, Chat: models.Chat{ID: 111, Type: models.ChatTypePrivate}, Text: "/api/v1",
	}})
	_, confirmation := botExtensionOnlyConfirmation(t, bt.extensionStateStore())
	mutation, err := decodeBotExtensionMutation(confirmation.RawJSON)
	if err != nil {
		t.Fatal(err)
	}
	if string(mutation.Settings["path"]) != `"/api/v1"` {
		t.Fatalf("slash-prefixed text value = %s", mutation.Settings["path"])
	}
}

func TestBotExtensionSelectOptionsArePagedAndSelectionsStayBounded(t *testing.T) {
	options := make([]string, 64)
	for index := range options {
		options[index] = "option-" + strconv.Itoa(index)
	}
	module := testModuleSnapshot()
	module.Settings = []interceptModuleSetting{{
		Key: "mode", Type: "select", Required: true, Options: options, Value: json.RawMessage(`"option-0"`),
	}}
	manager, _, _, _, _ := newInterceptManagerFixture(t, module)
	ctrl := NewController(func() error { return nil }, nil, nil, nil)
	ctrl.SetInterceptModuleManager(manager)
	bt, _ := newBotExtensionTelegramFixture(t, ctrl)
	view, err := ctrl.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	ctx := botExtensionTestOperation(t, bt)
	basePayload := botExtensionStatePayload{
		Kind: botExtensionPayloadSetting, Revision: view.Revision,
		ModuleID: module.ID, SettingKey: "mode", Digest: view.Modules[0].SnapshotDigest,
	}
	initial, _, err := bt.extensionStateStore().IssueSelectionForOperation(ctx, basePayload)
	if err != nil {
		t.Fatal(err)
	}
	bt.handleBotExtensionSettingCallback(ctx, bt.tg, botExtensionTestCallback(), 111, 111, initial)
	baseToken, count := currentBotExtensionSettingMenuState(t, bt.extensionStateStore())
	if count > 9 {
		t.Fatalf("first select page retained %d setting selections", count)
	}
	ctx = botExtensionTestOperation(t, bt)
	bt.handleBotExtensionSettingCallback(ctx, bt.tg, botExtensionTestCallback(), 111, 111, baseToken+":1")
	_, count = currentBotExtensionSettingMenuState(t, bt.extensionStateStore())
	if count > 9 {
		t.Fatalf("second select page retained %d setting selections", count)
	}
}

func currentBotExtensionSettingMenuState(t *testing.T, store *botExtensionStateStore) (string, int) {
	t.Helper()
	store.mu.Lock()
	defer store.mu.Unlock()
	base := ""
	count := 0
	for token, entry := range store.tokens {
		if entry.purpose != botExtensionTokenSelection || entry.payload.Kind != botExtensionPayloadSetting {
			continue
		}
		count++
		if entry.payload.StringValue == "" {
			base = token
		}
	}
	if base == "" {
		t.Fatal("select menu base token was not retained")
	}
	return base, count
}

func TestBotExtensionConfirmationRejectsCrossUserAndStaleRevision(t *testing.T) {
	store := newBotExtensionStateStore()
	payload := botExtensionStatePayload{
		Kind: botExtensionPayloadEnable, Revision: strings.Repeat("a", 64),
		ModuleID: "io.example.fixture", Digest: strings.Repeat("b", 64), BoolValue: true,
	}
	token, _, err := store.IssueConfirmation(111, 111, payload)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := store.ConsumeConfirmation(token, 222, 222, payload.Kind); ok {
		t.Fatal("cross-user confirmation was consumed")
	}
	if got, ok := store.ConsumeConfirmation(token, 111, 111, payload.Kind); !ok || got.ModuleID != payload.ModuleID {
		t.Fatal("cross-user attempt burned the real owner's confirmation")
	}

	module := testModuleSnapshot()
	manager, _, _, _, _ := newInterceptManagerFixture(t, module)
	ctrl := NewController(func() error { return nil }, nil, nil, nil)
	ctrl.SetInterceptModuleManager(manager)
	bt := &Bot{ctrl: ctrl}
	before, err := ctrl.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	stale := botExtensionStatePayload{
		Kind: botExtensionPayloadEnable, Revision: strings.Repeat("c", 64),
		ModuleID: module.ID, Digest: before.Modules[0].SnapshotDigest, BoolValue: true,
	}
	if err := bt.applyBotExtensionConfirmation(context.Background(), stale); !errors.Is(err, errInterceptRevisionConflict) {
		t.Fatalf("stale confirmation error = %v", err)
	}
	after, _ := ctrl.InterceptModules()
	if after.Revision != before.Revision || after.Modules[0].Enabled {
		t.Fatalf("stale confirmation mutated modules: before=%+v after=%+v", before, after)
	}
}

func TestBotExtensionOperationGenerationInvalidatesCancelledWork(t *testing.T) {
	store := newBotExtensionStateStore()
	owner, generation, err := store.BeginOperation(111, 111)
	if err != nil {
		t.Fatal(err)
	}
	ctx := withBotExtensionOperation(context.Background(), owner, generation)
	payload := botExtensionStatePayload{
		Kind: botExtensionPayloadEnable, Revision: strings.Repeat("a", 64),
		ModuleID: "io.example.fixture", Digest: strings.Repeat("b", 64), BoolValue: true,
	}
	if !store.CancelOwner(111, 111) {
		t.Fatal("cancel did not acknowledge an in-flight operation")
	}
	if _, _, err := store.IssueConfirmationForOperation(ctx, payload); err == nil {
		t.Fatal("cancelled operation issued a confirmation")
	}

	owner, generation, err = store.BeginOperation(111, 111)
	if err != nil {
		t.Fatal(err)
	}
	ctx = withBotExtensionOperation(context.Background(), owner, generation)
	token, _, err := store.IssueConfirmationForOperation(ctx, payload)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.BeginOperation(111, 111); err != nil {
		t.Fatal(err)
	}
	if _, ok := store.ConsumeConfirmation(token, 111, 111, payload.Kind); ok {
		t.Fatal("a newer operation did not invalidate the older confirmation")
	}
}

func TestBotExtensionGenerationDoesNotABAAfterPrune(t *testing.T) {
	now := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	store := newBotExtensionStateStoreWithOptions(botExtensionStateStoreOptions{
		now:          func() time.Time { return now },
		selectionTTL: time.Minute,
	})
	owner, first, err := store.BeginOperation(111, 111)
	if err != nil {
		t.Fatal(err)
	}
	old := botExtensionOperationContext{owner: owner, generation: first}
	now = now.Add(2 * time.Minute)
	_, second, err := store.BeginOperation(111, 111)
	if err != nil {
		t.Fatal(err)
	}
	if second == first || store.OperationCurrent(old) {
		t.Fatalf("generation ABA after prune: first=%d second=%d", first, second)
	}
}

func TestBotExtensionClaimedInputCancellationIsVisible(t *testing.T) {
	store := newBotExtensionStateStore()
	if _, err := store.BeginInput(111, 111, botExtensionInputModuleURL, botExtensionStatePayload{Kind: botExtensionPayloadInstall}); err != nil {
		t.Fatal(err)
	}
	_, owner, generation, ok := store.ClaimInput(111, 111)
	if !ok {
		t.Fatal("input was not claimed")
	}
	if !store.CancelOwner(111, 111) {
		t.Fatal("cancel did not report the claimed in-flight input")
	}
	ctx := withBotExtensionOperation(context.Background(), owner, generation)
	if _, _, err := store.IssueConfirmationForOperation(ctx, botExtensionStatePayload{Kind: botExtensionPayloadInstall}); err == nil {
		t.Fatal("claimed then cancelled input issued a confirmation")
	}
}

func TestBotExtensionCancelDuringBlockedPreviewCannotIssueConfirmation(t *testing.T) {
	fixture := newMarketplaceFixture(t, nil)
	_, modules, _ := newMarketplaceManagerFixture(t, fixture)
	started := make(chan struct{})
	var once sync.Once
	baseTransport := fixture.server.Client().Transport
	modules.parser.client.Transport = botExtensionRoundTripFunc(func(request *http.Request) (*http.Response, error) {
		once.Do(func() { close(started) })
		return baseTransport.RoundTrip(request)
	})
	ctrl := NewController(func() error { return nil }, nil, nil, nil)
	ctrl.SetInterceptModuleManager(modules)
	bt, _ := newBotExtensionTelegramFixture(t, ctrl)
	view, err := ctrl.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := bt.extensionStateStore().BeginInput(111, 111, botExtensionInputModuleURL, botExtensionStatePayload{
		Kind: botExtensionPayloadInstall, Revision: view.Revision,
	}); err != nil {
		t.Fatal(err)
	}
	fixture.mu.Lock()
	done := make(chan struct{})
	go func() {
		defer close(done)
		bt.handleExtensionInput(context.Background(), bt.tg, &models.Update{Message: &models.Message{
			From: &models.User{ID: 111}, Chat: models.Chat{ID: 111, Type: models.ChatTypePrivate},
			Text: fixture.server.URL + "/extension.yaml",
		}}, 111)
	}()
	<-started
	cancelUpdate := &models.Update{Message: &models.Message{
		From: &models.User{ID: 111}, Chat: models.Chat{ID: 111, Type: models.ChatTypePrivate}, Text: "/cancel",
	}}
	if !bt.cancelExtensionState(cancelUpdate) {
		fixture.mu.Unlock()
		t.Fatal("cancel did not acknowledge blocked preview")
	}
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		fixture.mu.Unlock()
		t.Fatal("blocked preview did not stop after cancellation")
	}
	fixture.mu.Unlock()
	store := bt.extensionStateStore()
	store.mu.Lock()
	defer store.mu.Unlock()
	for _, entry := range store.tokens {
		if entry.purpose == botExtensionTokenConfirmation {
			t.Fatal("cancelled blocked preview issued a confirmation")
		}
	}
}

func TestBotExtensionUninstallRequiresDisabledModule(t *testing.T) {
	module := testModuleSnapshot()
	module.Enabled = true
	manager, _, _, _, _ := newInterceptManagerFixture(t, module)
	ctrl := NewController(func() error { return nil }, nil, nil, nil)
	ctrl.SetInterceptModuleManager(manager)
	bt := &Bot{ctrl: ctrl}
	view, err := ctrl.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	payload := botExtensionStatePayload{
		Kind: botExtensionPayloadUninstall, Revision: view.Revision,
		ModuleID: module.ID, Digest: view.Modules[0].SnapshotDigest,
	}
	if err := bt.applyBotExtensionConfirmation(context.Background(), payload); err == nil || !strings.Contains(err.Error(), "disable") {
		t.Fatalf("enabled uninstall error = %v", err)
	}
	after, _ := ctrl.InterceptModules()
	if len(after.Modules) != 1 || !after.Modules[0].Enabled || after.Revision != view.Revision {
		t.Fatalf("enabled uninstall mutated module: %+v", after)
	}
}

func TestBotExtensionUpdateApplyKeepsReplacementDisabled(t *testing.T) {
	ctx := context.Background()
	fixture := newMarketplaceFixture(t, nil)
	_, modules, _ := newMarketplaceManagerFixture(t, fixture)
	ctrl := NewController(func() error { return nil }, nil, nil, nil)
	ctrl.SetInterceptModuleManager(modules)
	before, err := ctrl.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	request := interceptModuleImportRequest{
		Revision: before.Revision,
		URL:      fixture.server.URL + "/extension.yaml",
	}
	preview, err := ctrl.PreviewInterceptModuleImport(ctx, request)
	if err != nil {
		t.Fatal(err)
	}
	installed, err := ctrl.ImportInterceptModuleExpected(ctx, request, preview.SnapshotDigest)
	if err != nil {
		t.Fatal(err)
	}
	fixture.mu.Lock()
	fixture.manifest = strings.Replace(fixture.manifest, "version: 1.0.0", "version: 1.0.1", 1)
	fixture.mu.Unlock()
	check, err := ctrl.CheckInterceptModuleUpdate(ctx, preview.ID, installed.Revision)
	if err != nil {
		t.Fatal(err)
	}
	if check.Candidate == nil {
		t.Fatalf("update check = %+v", check)
	}
	payload := botExtensionStatePayload{
		Kind:            botExtensionPayloadUpdate,
		Revision:        installed.Revision,
		ModuleID:        installed.Modules[0].ID,
		Digest:          installed.Modules[0].SnapshotDigest,
		CandidateDigest: check.Candidate.SnapshotDigest,
	}
	bt := &Bot{ctrl: ctrl}
	if err := bt.applyBotExtensionConfirmation(ctx, payload); err != nil {
		t.Fatal(err)
	}
	after, err := ctrl.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	if len(after.Modules) != 1 || after.Modules[0].Enabled || after.Modules[0].Version != "1.0.1" || after.Modules[0].SnapshotDigest != check.Candidate.SnapshotDigest {
		t.Fatalf("updated module = %+v", after.Modules)
	}
}
