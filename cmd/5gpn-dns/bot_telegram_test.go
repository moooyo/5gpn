package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	telegram "github.com/go-telegram/bot"
	"github.com/go-telegram/bot/models"
)

type telegramCallLog struct {
	mu      sync.Mutex
	methods []string
	forms   map[string][]string
}

func (l *telegramCallLog) add(method string, values map[string][]string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.methods = append(l.methods, method)
	for k, v := range values {
		l.forms[method+":"+k] = append([]string(nil), v...)
	}
}

func (l *telegramCallLog) saw(method string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, got := range l.methods {
		if got == method {
			return true
		}
	}
	return false
}

func newFakeTelegramServer(t *testing.T, webhookURL string, updates chan<- struct{}) (*httptest.Server, *telegramCallLog) {
	t.Helper()
	log := &telegramCallLog{forms: make(map[string][]string)}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseMultipartForm(1 << 20); err != nil && !errors.Is(err, io.EOF) {
			t.Errorf("parse Telegram request: %v", err)
			http.Error(w, "bad form", http.StatusBadRequest)
			return
		}
		method := r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:]
		values := map[string][]string{}
		if r.MultipartForm != nil {
			values = r.MultipartForm.Value
		}
		log.add(method, values)
		w.Header().Set("Content-Type", "application/json")
		switch method {
		case "getMe":
			_, _ = w.Write([]byte(`{"ok":true,"result":{"id":123,"is_bot":true,"first_name":"5gpn","username":"fivegpn_bot"}}`))
		case "getWebhookInfo":
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "result": map[string]any{"url": webhookURL, "has_custom_certificate": false, "pending_update_count": 0}})
		case "deleteWebhook", "setMyCommands", "deleteMyCommands", "answerCallbackQuery":
			_, _ = w.Write([]byte(`{"ok":true,"result":true}`))
		case "sendMessage", "editMessageText", "sendPhoto", "sendDocument":
			_, _ = w.Write([]byte(`{"ok":true,"result":{"message_id":1,"date":1,"chat":{"id":111,"type":"private"}}}`))
		case "getUpdates":
			select {
			case updates <- struct{}{}:
			default:
			}
			_, _ = w.Write([]byte(`{"ok":true,"result":[]}`))
		default:
			t.Errorf("unexpected Telegram method %q", method)
			http.Error(w, "unexpected", http.StatusNotFound)
		}
	}))
	return server, log
}

func TestNewBotTakesOverWebhookAndDeclaresAllowedUpdates(t *testing.T) {
	updates := make(chan struct{}, 1)
	server, calls := newFakeTelegramServer(t, "https://old.example/hook", updates)
	defer server.Close()

	bt, err := newBotWithOptions(Config{
		TGBotToken:  "123:test-token",
		TGBotAdmins: map[int64]bool{111: true},
	}, &Controller{}, telegram.WithServerURL(server.URL))
	if err != nil {
		t.Fatalf("newBotWithOptions: %v", err)
	}
	if !calls.saw("getWebhookInfo") || !calls.saw("deleteWebhook") {
		t.Fatalf("webhook preflight calls = %v, want getWebhookInfo + deleteWebhook", calls.methods)
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		bt.Run(ctx)
		close(done)
	}()
	select {
	case <-updates:
		cancel()
	case <-time.After(3 * time.Second):
		cancel()
		t.Fatal("bot did not start getUpdates")
	}
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("bot did not stop after cancellation")
	}

	calls.mu.Lock()
	allowed := append([]string(nil), calls.forms["getUpdates:allowed_updates"]...)
	methods := append([]string(nil), calls.methods...)
	calls.mu.Unlock()
	if len(allowed) != 1 || !strings.Contains(allowed[0], `"message"`) || !strings.Contains(allowed[0], `"callback_query"`) {
		t.Fatalf("allowed_updates = %v, methods=%v", allowed, methods)
	}
	if !calls.saw("setMyCommands") {
		t.Fatalf("setMyCommands not called; methods=%v", methods)
	}
}

func TestNewBotKeepsEmptyWebhook(t *testing.T) {
	updates := make(chan struct{}, 1)
	server, calls := newFakeTelegramServer(t, "", updates)
	defer server.Close()
	if _, err := newBotWithOptions(Config{TGBotToken: "123:test-token"}, &Controller{}, telegram.WithServerURL(server.URL)); err != nil {
		t.Fatalf("newBotWithOptions: %v", err)
	}
	if calls.saw("deleteWebhook") {
		t.Fatal("empty webhook should not be deleted")
	}
}

func TestTelegramHTTPClientUsesDedicatedProxy(t *testing.T) {
	client, err := newTGBotHTTPClient("http://user:secret@127.0.0.1:7890")
	if err != nil {
		t.Fatal(err)
	}
	transport, ok := client.Transport.(*http.Transport)
	if !ok {
		t.Fatalf("transport type = %T", client.Transport)
	}
	req := httptest.NewRequest(http.MethodGet, "https://api.telegram.org/bot123/getMe", nil)
	proxyURL, err := transport.Proxy(req)
	if err != nil {
		t.Fatal(err)
	}
	if proxyURL == nil || proxyURL.Host != "127.0.0.1:7890" || proxyURL.User.Username() != "user" {
		t.Fatalf("proxy URL = %v", proxyURL)
	}
}

func TestTelegramHTTPClientDoesNotUseAmbientProxy(t *testing.T) {
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:65534")
	client, err := newTGBotHTTPClient("")
	if err != nil {
		t.Fatal(err)
	}
	transport, ok := client.Transport.(*http.Transport)
	if !ok {
		t.Fatalf("transport type = %T", client.Transport)
	}
	if transport.Proxy != nil {
		t.Fatal("empty TGBOT_PROXY_URL inherited an ambient proxy")
	}
}

func privateCallback(data string) *models.Update {
	return &models.Update{CallbackQuery: &models.CallbackQuery{
		ID:   "callback-id",
		From: models.User{ID: 111},
		Data: data,
		Message: models.MaybeInaccessibleMessage{
			Type: models.MaybeInaccessibleMessageTypeMessage,
			Message: &models.Message{
				ID:   9,
				Date: 1,
				Chat: models.Chat{ID: 111, Type: models.ChatTypePrivate},
			},
		},
	}}
}

func TestCallbackRouterDiagnosis(t *testing.T) {
	updates := make(chan struct{}, 1)
	server, calls := newFakeTelegramServer(t, "", updates)
	defer server.Close()
	bt, err := newBotWithOptions(Config{
		TGBotToken:  "123:test-token",
		TGBotAdmins: map[int64]bool{111: true},
	}, &Controller{}, telegram.WithServerURL(server.URL))
	if err != nil {
		t.Fatal(err)
	}

	bt.handleCallback(context.Background(), bt.tg, privateCallback("b1:act:diagnose"))
	if pending, ok := bt.getPending(111); !ok || pending != "diagnose" {
		t.Fatalf("diagnose callback pending = %q,%v", pending, ok)
	}
	if !calls.saw("answerCallbackQuery") || !calls.saw("editMessageText") {
		t.Fatalf("callback was not acknowledged/edited: %v", calls.methods)
	}

}

func TestConfirmedCallbackIsOneUse(t *testing.T) {
	updates := make(chan struct{}, 1)
	server, _ := newFakeTelegramServer(t, "", updates)
	defer server.Close()
	bt, err := newBotWithOptions(Config{
		TGBotToken:  "123:test-token",
		TGBotAdmins: map[int64]bool{111: true},
	}, &Controller{}, telegram.WithServerURL(server.URL))
	if err != nil {
		t.Fatal(err)
	}
	bt.runFn = func(argv []string, _ time.Duration) (bool, string) {
		if len(argv) >= 2 && argv[1] == "restart" {
			return true, ""
		}
		return true, "active"
	}
	nonce, _, err := bt.actionGuard().Issue(botActionRestartMihomo, 111, 111)
	if err != nil {
		t.Fatal(err)
	}
	data := "b1:confirm:" + string(botActionRestartMihomo) + ":" + nonce
	bt.handleCallback(context.Background(), bt.tg, privateCallback(data))
	if bt.actionGuard().Consume(nonce, botActionRestartMihomo, 111, 111) {
		t.Fatal("confirmation nonce remained reusable after execution")
	}

	var repeatedCalls int
	bt.runFn = func([]string, time.Duration) (bool, string) {
		repeatedCalls++
		return true, "active"
	}
	bt.handleCallback(context.Background(), bt.tg, privateCallback(data))
	if repeatedCalls != 0 {
		t.Fatalf("replayed confirmation executed %d subprocesses", repeatedCalls)
	}
}

func TestAdminGateRejectsGroupBeforeHandler(t *testing.T) {
	updates := make(chan struct{}, 1)
	server, calls := newFakeTelegramServer(t, "", updates)
	defer server.Close()
	bt, err := newBotWithOptions(Config{
		TGBotToken:  "123:test-token",
		TGBotAdmins: map[int64]bool{111: true},
	}, &Controller{}, telegram.WithServerURL(server.URL))
	if err != nil {
		t.Fatal(err)
	}
	called := false
	handler := bt.adminGate(func(context.Context, *telegram.Bot, *models.Update) { called = true })
	handler(context.Background(), bt.tg, &models.Update{Message: &models.Message{
		From: &models.User{ID: 111},
		Chat: models.Chat{ID: -100, Type: models.ChatTypeSupergroup},
		Text: "/status",
	}})
	if called {
		t.Fatal("authorized user bypassed private-chat restriction in a group")
	}
	if !calls.saw("sendMessage") {
		t.Fatal("group rejection did not provide a safe explanation")
	}
}

func TestLongLogsUseProtectedDocument(t *testing.T) {
	updates := make(chan struct{}, 1)
	server, calls := newFakeTelegramServer(t, "", updates)
	defer server.Close()
	bt, err := newBotWithOptions(Config{TGBotToken: "123:test-token"}, &Controller{}, telegram.WithServerURL(server.URL))
	if err != nil {
		t.Fatal(err)
	}
	if !bt.sendLogDocument(context.Background(), bt.tg, 111, "5gpn-dns", strings.Repeat("日志行\n", 1000)) {
		t.Fatal("sendLogDocument failed")
	}
	if !calls.saw("sendDocument") {
		t.Fatal("long log document did not use Telegram sendDocument")
	}
}
