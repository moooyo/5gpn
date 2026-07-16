package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"

	telegram "github.com/go-telegram/bot"
)

// fakeTGBotManager records Apply calls and returns a fixed View, so the API
// handlers can be tested without a live bot supervisor.
type fakeTGBotManager struct {
	view     TGBotView
	applyErr error
	gotToken *string
	gotAdms  []int64
	called   bool
}

func (f *fakeTGBotManager) View() TGBotView { return f.view }
func (f *fakeTGBotManager) Apply(tokenPtr *string, admins []int64) error {
	f.called = true
	f.gotToken = tokenPtr
	f.gotAdms = admins
	return f.applyErr
}

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return b
}

// TestAPITGBot_GetRedactsToken: GET /api/tgbot returns the admins/token_set/
// running view and NEVER a raw token field.
func TestAPITGBot_GetRedactsToken(t *testing.T) {
	cs, token := newAPITestServer(t)
	cs.ctrl.SetTGBotManager(&fakeTGBotManager{
		view: TGBotView{AdminIDs: []int64{111, 222}, TokenSet: true, State: botStateHealthy},
	})

	rec := doAPI(cs, http.MethodGet, "/api/tgbot", nil, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), `"token"`) {
		t.Errorf("GET /api/tgbot leaked a token field: %s", rec.Body.String())
	}
	var got TGBotView
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("response not JSON: %v", err)
	}
	if !got.TokenSet || got.State != botStateHealthy || len(got.AdminIDs) != 2 {
		t.Errorf("view = %+v", got)
	}
}

// TestAPITGBot_Put forwards token+admins to Apply, and an OMITTED token becomes a
// nil pointer (keep-current) rather than an empty string (disable).
func TestAPITGBot_Put(t *testing.T) {
	cs, token := newAPITestServer(t)
	mgr := &fakeTGBotManager{view: TGBotView{AdminIDs: []int64{}, State: botStateDisabled}}
	cs.ctrl.SetTGBotManager(mgr)

	// Explicit token.
	body := mustJSON(t, map[string]any{"token": "abc", "admins": []int64{1, 2}})
	rec := doAPI(cs, http.MethodPut, "/api/tgbot", body, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("PUT status = %d; body=%s", rec.Code, rec.Body.String())
	}
	if !mgr.called || mgr.gotToken == nil || *mgr.gotToken != "abc" {
		t.Errorf("Apply token not forwarded: called=%v token=%v", mgr.called, mgr.gotToken)
	}
	if len(mgr.gotAdms) != 2 {
		t.Errorf("Apply admins = %v, want 2", mgr.gotAdms)
	}

	// Omitted token → nil pointer (admins-only edit keeps the current token).
	mgr.called, mgr.gotToken = false, new(string)
	body = mustJSON(t, map[string]any{"admins": []int64{9}})
	rec = doAPI(cs, http.MethodPut, "/api/tgbot", body, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("PUT (omit token) status = %d", rec.Code)
	}
	if mgr.gotToken != nil {
		t.Errorf("an omitted token must decode to nil (keep current), got %q", *mgr.gotToken)
	}
}

// TestAPITGBot_Unavailable: with no wired manager, GET degrades to an empty view
// (200) and PUT is a 503 — never a panic.
func TestAPITGBot_Unavailable(t *testing.T) {
	cs, token := newAPITestServer(t)
	// No SetTGBotManager.

	rec := doAPI(cs, http.MethodGet, "/api/tgbot", nil, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET status = %d, want 200 (empty view)", rec.Code)
	}
	body := mustJSON(t, map[string]any{"admins": []int64{}})
	rec = doAPI(cs, http.MethodPut, "/api/tgbot", body, token, true)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("PUT (unwired) status = %d, want 503", rec.Code)
	}
}

func TestAPITGBot_ErrorStatus(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
		want int
	}{
		{name: "invalid token", err: fmt.Errorf("telegram bot: %w", telegram.ErrorUnauthorized), want: http.StatusBadRequest},
		{name: "Telegram unavailable", err: fmt.Errorf("telegram bot: network timeout"), want: http.StatusBadGateway},
		{name: "superseded", err: fmt.Errorf("telegram bot: %w", errBotConfigSuperseded), want: http.StatusConflict},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cs, token := newAPITestServer(t)
			cs.ctrl.SetTGBotManager(&fakeTGBotManager{applyErr: tc.err})
			body := mustJSON(t, map[string]any{"token": "candidate", "admins": []int64{1}})
			rec := doAPI(cs, http.MethodPut, "/api/tgbot", body, token, true)
			if rec.Code != tc.want {
				t.Fatalf("status=%d body=%s, want %d", rec.Code, rec.Body.String(), tc.want)
			}
		})
	}
}
