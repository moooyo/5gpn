package main

import (
	"bytes"
	"errors"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func botExtensionTestEntropy(blocks int) *bytes.Reader {
	data := make([]byte, blocks*botExtensionTokenBytes)
	for block := 0; block < blocks; block++ {
		for index := 0; index < botExtensionTokenBytes; index++ {
			data[block*botExtensionTokenBytes+index] = byte(block + 1)
		}
	}
	return bytes.NewReader(data)
}

func TestBotExtensionStateConfirmationLifecycle(t *testing.T) {
	now := time.Date(2026, time.July, 20, 12, 0, 0, 0, time.UTC)
	store := newBotExtensionStateStoreWithOptions(botExtensionStateStoreOptions{
		now:             func() time.Time { return now },
		entropy:         botExtensionTestEntropy(4),
		confirmationTTL: 90 * time.Second,
	})
	payload := botExtensionStatePayload{
		Kind:           botExtensionPayloadEnable,
		Revision:       "market-revision",
		ModuleRevision: "module-revision",
		ModuleID:       "io.example.weather",
		SourceID:       "official",
		EntryID:        "weather",
		SettingKey:     "location",
		Digest:         strings.Repeat("a", 64),
		BoolValue:      true,
		StringValue:    "DIRECT",
		RawJSON:        []byte(`{"location":{"latitude":31.2,"longitude":121.5}}`),
	}
	want := cloneBotExtensionPayload(payload)
	token, expiresAt, err := store.IssueConfirmation(7, 11, payload)
	if err != nil {
		t.Fatalf("IssueConfirmation: %v", err)
	}
	if !validBotExtensionToken(token) || len(token) != 16 {
		t.Fatalf("token = %q, want a 16-character opaque token", token)
	}
	if callback := "bx:confirm:enable:" + token; len(callback) >= 64 {
		t.Fatalf("callback length = %d, want less than Telegram's 64-byte limit", len(callback))
	}
	if !expiresAt.Equal(now.Add(90 * time.Second)) {
		t.Fatalf("expiresAt = %v", expiresAt)
	}

	// The caller cannot mutate the stored review after it is issued.
	payload.RawJSON[0] = '!'
	if _, ok := store.ConsumeConfirmation(token, 8, 11, botExtensionPayloadEnable); ok {
		t.Fatal("another administrator consumed the confirmation")
	}
	if _, ok := store.ConsumeConfirmation(token, 7, 12, botExtensionPayloadEnable); ok {
		t.Fatal("another private chat consumed the confirmation")
	}
	if _, ok := store.ConsumeConfirmation(token, 7, 11, botExtensionPayloadDisable); ok {
		t.Fatal("a mismatched mutation kind consumed the confirmation")
	}
	if _, ok := store.ConsumeSelection(token, 7, 11, botExtensionPayloadEnable); ok {
		t.Fatal("a confirmation token was accepted as a selection token")
	}

	got, ok := store.ConsumeConfirmation(token, 7, 11, botExtensionPayloadEnable)
	if !ok || !reflect.DeepEqual(got, want) {
		t.Fatalf("ConsumeConfirmation = (%+v, %v), want (%+v, true)", got, ok, want)
	}
	got.RawJSON[0] = '?'
	if _, ok := store.ConsumeConfirmation(token, 7, 11, botExtensionPayloadEnable); ok {
		t.Fatal("confirmation was reusable")
	}

	cancelToken, _, err := store.IssueConfirmation(7, 11, botExtensionStatePayload{Kind: botExtensionPayloadDisable})
	if err != nil {
		t.Fatal(err)
	}
	if store.CancelConfirmation(cancelToken, 8, 11) {
		t.Fatal("another administrator cancelled the confirmation")
	}
	if !store.CancelConfirmation(cancelToken, 7, 11) {
		t.Fatal("owner could not cancel the confirmation")
	}
	if _, ok := store.ConsumeConfirmation(cancelToken, 7, 11, botExtensionPayloadDisable); ok {
		t.Fatal("cancelled confirmation remained usable")
	}
}

func TestBotExtensionStateConfirmationReplacementAndConcurrency(t *testing.T) {
	store := newBotExtensionStateStoreWithOptions(botExtensionStateStoreOptions{
		entropy:   botExtensionTestEntropy(4),
		maxTokens: 1,
	})
	first, _, err := store.IssueConfirmation(1, 1, botExtensionStatePayload{
		Kind: botExtensionPayloadEnable, Revision: "old",
	})
	if err != nil {
		t.Fatal(err)
	}
	second, _, err := store.IssueConfirmation(1, 1, botExtensionStatePayload{
		Kind: botExtensionPayloadEnable, Revision: "new",
	})
	if err != nil {
		t.Fatalf("same-kind replacement at capacity: %v", err)
	}
	if _, ok := store.ConsumeConfirmation(first, 1, 1, botExtensionPayloadEnable); ok {
		t.Fatal("replacement left the old confirmation live")
	}

	const consumers = 64
	var successes atomic.Int32
	var wg sync.WaitGroup
	wg.Add(consumers)
	for index := 0; index < consumers; index++ {
		go func() {
			defer wg.Done()
			if payload, ok := store.ConsumeConfirmation(second, 1, 1, botExtensionPayloadEnable); ok {
				if payload.Revision != "new" {
					t.Errorf("revision = %q", payload.Revision)
				}
				successes.Add(1)
			}
		}()
	}
	wg.Wait()
	if got := successes.Load(); got != 1 {
		t.Fatalf("successful concurrent consumes = %d, want 1", got)
	}
}

func TestBotExtensionStateSelectionBindingAndCopy(t *testing.T) {
	store := newBotExtensionStateStoreWithOptions(botExtensionStateStoreOptions{
		entropy: botExtensionTestEntropy(3),
	})
	original := botExtensionStatePayload{
		Kind:     botExtensionPayloadMarketplaceEntry,
		Revision: "market-revision",
		SourceID: "official",
		EntryID:  "io.example.weather",
		RawJSON:  []byte("not-json-but-valid-opaque-local-data"),
	}
	want := cloneBotExtensionPayload(original)
	token, _, err := store.IssueSelection(101, 201, original)
	if err != nil {
		t.Fatal(err)
	}
	original.RawJSON[0] = '!'
	for _, attempt := range []struct {
		adminID int64
		chatID  int64
		kind    botExtensionPayloadKind
	}{
		{adminID: 102, chatID: 201, kind: botExtensionPayloadMarketplaceEntry},
		{adminID: 101, chatID: 202, kind: botExtensionPayloadMarketplaceEntry},
		{adminID: 101, chatID: 201, kind: botExtensionPayloadModule},
	} {
		if _, ok := store.ResolveSelection(token, attempt.adminID, attempt.chatID, attempt.kind); ok {
			t.Fatalf("cross-owner/kind selection accepted: %+v", attempt)
		}
	}

	first, ok := store.ResolveSelection(token, 101, 201, botExtensionPayloadMarketplaceEntry)
	if !ok || !reflect.DeepEqual(first, want) {
		t.Fatalf("first ResolveSelection = (%+v, %v)", first, ok)
	}
	first.RawJSON[0] = '?'
	second, ok := store.ResolveSelection(token, 101, 201, botExtensionPayloadMarketplaceEntry)
	if !ok || !reflect.DeepEqual(second, want) {
		t.Fatalf("second ResolveSelection exposed a mutable alias: (%+v, %v)", second, ok)
	}
	if _, ok := store.ConsumeSelection(token, 101, 201, botExtensionPayloadMarketplaceEntry); !ok {
		t.Fatal("owner could not consume selection")
	}
	if _, ok := store.ResolveSelection(token, 101, 201, botExtensionPayloadMarketplaceEntry); ok {
		t.Fatal("consumed selection remained live")
	}
}

func TestBotExtensionStateInputKindsIsolationAndCancellation(t *testing.T) {
	kinds := []botExtensionInputKind{
		botExtensionInputMarketplaceURL,
		botExtensionInputMarketplaceName,
		botExtensionInputModuleURL,
		botExtensionInputLocalYAML,
		botExtensionInputSettingText,
		botExtensionInputSettingNumber,
		botExtensionInputSettingLocation,
	}
	store := newBotExtensionStateStore()
	for index, kind := range kinds {
		adminID := int64(100 + index)
		chatID := int64(200 + index)
		raw := []byte("apiVersion: 5gpn.io/v1\nkind: Extension\n")
		want := botExtensionStatePayload{
			Kind:       botExtensionPayloadSetting,
			Revision:   "revision",
			ModuleID:   "io.example.fixture",
			SettingKey: string(kind),
			RawJSON:    append([]byte(nil), raw...),
		}
		if _, err := store.BeginInput(adminID, chatID, kind, botExtensionStatePayload{
			Kind:       want.Kind,
			Revision:   want.Revision,
			ModuleID:   want.ModuleID,
			SettingKey: want.SettingKey,
			RawJSON:    raw,
		}); err != nil {
			t.Fatalf("BeginInput(%q): %v", kind, err)
		}
		raw[0] = '!'
		if _, ok := store.Input(adminID+1, chatID); ok {
			t.Fatalf("input %q crossed administrator boundary", kind)
		}
		if _, ok := store.Input(adminID, chatID+1); ok {
			t.Fatalf("input %q crossed chat boundary", kind)
		}
		state, ok := store.Input(adminID, chatID)
		if !ok || state.Kind != kind || !reflect.DeepEqual(state.Payload, want) {
			t.Fatalf("Input(%q) = (%+v, %v)", kind, state, ok)
		}
		state.Payload.RawJSON[0] = '?'
		mismatch := botExtensionInputSettingText
		if kind == mismatch {
			mismatch = botExtensionInputSettingNumber
		}
		if _, ok := store.ConsumeInput(adminID, chatID, mismatch); ok {
			t.Fatalf("mismatched input kind consumed %q", kind)
		}
		got, ok := store.ConsumeInput(adminID, chatID, kind)
		if !ok || !reflect.DeepEqual(got, want) {
			t.Fatalf("ConsumeInput(%q) = (%+v, %v)", kind, got, ok)
		}
		if _, ok := store.ConsumeInput(adminID, chatID, kind); ok {
			t.Fatalf("input %q was reusable", kind)
		}
	}

	if _, err := store.BeginInput(1, 1, botExtensionInputMarketplaceURL, botExtensionStatePayload{Kind: botExtensionPayloadMarketplaceAdd}); err != nil {
		t.Fatal(err)
	}
	if !store.CancelInput(1, 1) || store.CancelInput(1, 1) {
		t.Fatal("CancelInput did not have one-use cancellation semantics")
	}
}

func TestBotExtensionStateExpirationPrunesAllState(t *testing.T) {
	now := time.Date(2026, time.July, 20, 12, 0, 0, 0, time.UTC)
	store := newBotExtensionStateStoreWithOptions(botExtensionStateStoreOptions{
		now:             func() time.Time { return now },
		entropy:         botExtensionTestEntropy(4),
		confirmationTTL: time.Minute,
		selectionTTL:    time.Minute,
		inputTTL:        time.Minute,
	})
	confirmation, _, err := store.IssueConfirmation(1, 1, botExtensionStatePayload{Kind: botExtensionPayloadEnable, RawJSON: []byte("confirm")})
	if err != nil {
		t.Fatal(err)
	}
	selection, _, err := store.IssueSelection(1, 1, botExtensionStatePayload{Kind: botExtensionPayloadModule, RawJSON: []byte("select")})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.BeginInput(1, 1, botExtensionInputLocalYAML, botExtensionStatePayload{Kind: botExtensionPayloadInstall, RawJSON: []byte("manifest")}); err != nil {
		t.Fatal(err)
	}
	if store.usedBytes == 0 {
		t.Fatal("test did not populate byte accounting")
	}

	now = now.Add(time.Minute)
	if _, ok := store.ConsumeConfirmation(confirmation, 1, 1, botExtensionPayloadEnable); ok {
		t.Fatal("expired confirmation was accepted")
	}
	if _, ok := store.ResolveSelection(selection, 1, 1, botExtensionPayloadModule); ok {
		t.Fatal("expired selection was accepted")
	}
	if _, ok := store.Input(1, 1); ok {
		t.Fatal("expired input was returned")
	}
	if len(store.tokens) != 0 || len(store.inputs) != 0 || store.usedBytes != 0 {
		t.Fatalf("expired state not pruned: tokens=%d inputs=%d bytes=%d", len(store.tokens), len(store.inputs), store.usedBytes)
	}
}

func TestBotExtensionStateCapacityAndPayloadBounds(t *testing.T) {
	store := newBotExtensionStateStoreWithOptions(botExtensionStateStoreOptions{
		entropy:         botExtensionTestEntropy(8),
		maxTokens:       2,
		maxInputs:       1,
		maxPayloadBytes: 64,
		maxStateBytes:   128,
	})
	for index := 0; index < 2; index++ {
		if _, _, err := store.IssueSelection(int64(index+1), int64(index+1), botExtensionStatePayload{
			Kind: botExtensionPayloadModule, ModuleID: string(rune('a' + index)),
		}); err != nil {
			t.Fatalf("IssueSelection %d: %v", index, err)
		}
	}
	if _, _, err := store.IssueSelection(3, 3, botExtensionStatePayload{Kind: botExtensionPayloadModule}); !errors.Is(err, errBotExtensionStateFull) {
		t.Fatalf("token capacity error = %v", err)
	}

	if _, err := store.BeginInput(10, 10, botExtensionInputLocalYAML, botExtensionStatePayload{Kind: botExtensionPayloadInstall}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.BeginInput(11, 11, botExtensionInputLocalYAML, botExtensionStatePayload{Kind: botExtensionPayloadInstall}); !errors.Is(err, errBotExtensionStateFull) {
		t.Fatalf("input capacity error = %v", err)
	}
	if _, err := store.BeginInput(10, 10, botExtensionInputSettingLocation, botExtensionStatePayload{Kind: botExtensionPayloadSetting, RawJSON: []byte(`{"latitude":1}`)}); err != nil {
		t.Fatalf("same-owner input replacement at capacity: %v", err)
	}

	large := botExtensionStatePayload{Kind: botExtensionPayloadInstall, RawJSON: bytes.Repeat([]byte{'x'}, 65)}
	if _, err := store.BeginInput(10, 10, botExtensionInputLocalYAML, large); !errors.Is(err, errBotExtensionPayloadTooLarge) {
		t.Fatalf("oversized payload error = %v", err)
	}
	state, ok := store.Input(10, 10)
	if !ok || state.Kind != botExtensionInputSettingLocation {
		t.Fatalf("failed replacement destroyed prior input: (%+v, %v)", state, ok)
	}
}

func TestBotExtensionStateTotalByteBudgetAndCancelOwner(t *testing.T) {
	firstPayload := botExtensionStatePayload{Kind: botExtensionPayloadModule, RawJSON: []byte("12345678")}
	firstSize, err := validateBotExtensionPayload(firstPayload)
	if err != nil {
		t.Fatal(err)
	}
	store := newBotExtensionStateStoreWithOptions(botExtensionStateStoreOptions{
		entropy:         botExtensionTestEntropy(6),
		maxTokens:       10,
		maxInputs:       10,
		maxPayloadBytes: firstSize,
		maxStateBytes:   firstSize,
	})
	token, _, err := store.IssueSelection(1, 1, firstPayload)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.BeginInput(2, 2, botExtensionInputLocalYAML, botExtensionStatePayload{Kind: botExtensionPayloadInstall}); !errors.Is(err, errBotExtensionStateFull) {
		t.Fatalf("total byte budget error = %v", err)
	}
	if !store.CancelSelection(token, 1, 1) {
		t.Fatal("owner could not release selection state")
	}
	if _, err := store.BeginInput(2, 2, botExtensionInputLocalYAML, botExtensionStatePayload{Kind: botExtensionPayloadInstall}); err != nil {
		t.Fatalf("released bytes were not reusable: %v", err)
	}

	cancelStore := newBotExtensionStateStoreWithOptions(botExtensionStateStoreOptions{entropy: botExtensionTestEntropy(4)})
	if _, err := cancelStore.BeginInput(2, 2, botExtensionInputLocalYAML, botExtensionStatePayload{Kind: botExtensionPayloadInstall}); err != nil {
		t.Fatal(err)
	}
	ownerToken, _, err := cancelStore.IssueConfirmation(2, 2, botExtensionStatePayload{Kind: botExtensionPayloadEnable})
	if err != nil {
		t.Fatal(err)
	}
	otherToken, _, err := cancelStore.IssueConfirmation(3, 3, botExtensionStatePayload{Kind: botExtensionPayloadDisable})
	if err != nil {
		t.Fatal(err)
	}
	if !cancelStore.CancelOwner(2, 2) {
		t.Fatal("CancelOwner removed nothing")
	}
	if _, ok := cancelStore.Input(2, 2); ok {
		t.Fatal("CancelOwner left input state")
	}
	if _, ok := cancelStore.ConsumeConfirmation(ownerToken, 2, 2, botExtensionPayloadEnable); ok {
		t.Fatal("CancelOwner left a confirmation")
	}
	if _, ok := cancelStore.ConsumeConfirmation(otherToken, 3, 3, botExtensionPayloadDisable); !ok {
		t.Fatal("CancelOwner removed another owner's token")
	}
}

func TestBotExtensionStateCancelOwnerDistinguishesActiveWorkFromGenerationTombstone(t *testing.T) {
	store := newBotExtensionStateStore()
	owner, generation, err := store.BeginOperation(7, 7)
	if err != nil {
		t.Fatal(err)
	}
	operation := botExtensionOperationContext{owner: owner, generation: generation}
	if !store.CancelOwner(7, 7) {
		t.Fatal("active operation was not reported as cancelled")
	}
	if store.OperationCurrent(operation) {
		t.Fatal("cancelled operation remained current")
	}
	if store.CancelOwner(7, 7) {
		t.Fatal("generation tombstone was reported as pending work")
	}

	owner, generation, err = store.BeginOperation(8, 8)
	if err != nil {
		t.Fatal(err)
	}
	store.FinishOperation(botExtensionOperationContext{owner: owner, generation: generation})
	if store.CancelOwner(8, 8) {
		t.Fatal("finished operation was reported as pending work")
	}
}

func TestBotExtensionStateEntropyCollisionAndValidation(t *testing.T) {
	collisionEntropy := append(bytes.Repeat([]byte{0x42}, botExtensionTokenBytes), bytes.Repeat([]byte{0x42}, botExtensionTokenBytes)...)
	collisionEntropy = append(collisionEntropy, bytes.Repeat([]byte{0x43}, botExtensionTokenBytes)...)
	store := newBotExtensionStateStoreWithOptions(botExtensionStateStoreOptions{entropy: bytes.NewReader(collisionEntropy)})
	first, _, err := store.IssueSelection(1, 1, botExtensionStatePayload{Kind: botExtensionPayloadModule})
	if err != nil {
		t.Fatal(err)
	}
	second, _, err := store.IssueSelection(1, 1, botExtensionStatePayload{Kind: botExtensionPayloadMarketplaceEntry})
	if err != nil {
		t.Fatalf("collision was not retried: %v", err)
	}
	if first == second {
		t.Fatal("token collision was accepted")
	}

	broken := newBotExtensionStateStoreWithOptions(botExtensionStateStoreOptions{entropy: bytes.NewReader(nil)})
	if _, _, err := broken.IssueConfirmation(1, 1, botExtensionStatePayload{Kind: botExtensionPayloadEnable}); err == nil {
		t.Fatal("entropy failure was ignored")
	}
	if _, _, err := store.IssueConfirmation(0, 1, botExtensionStatePayload{Kind: botExtensionPayloadEnable}); err == nil {
		t.Fatal("non-positive administrator id was accepted")
	}
	if _, _, err := store.IssueConfirmation(1, -1, botExtensionStatePayload{Kind: botExtensionPayloadEnable}); err == nil {
		t.Fatal("non-private chat id was accepted")
	}
	if _, _, err := store.IssueConfirmation(1, 1, botExtensionStatePayload{}); err == nil {
		t.Fatal("empty payload kind was accepted")
	}
	if _, err := store.BeginInput(1, 1, botExtensionInputKind("unknown"), botExtensionStatePayload{Kind: botExtensionPayloadSetting}); err == nil {
		t.Fatal("unknown input kind was accepted")
	}
	if _, _, err := store.IssueSelection(1, 1, botExtensionStatePayload{
		Kind: botExtensionPayloadModule, StringValue: strings.Repeat("x", maxBotExtensionStringBytes+1),
	}); err == nil {
		t.Fatal("oversized string field was accepted")
	}
}
