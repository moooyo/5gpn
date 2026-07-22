package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"
	"time"
	"unicode/utf8"
)

const (
	botExtensionTokenBytes = 12

	defaultBotExtensionConfirmationTTL = 2 * time.Minute
	defaultBotExtensionSelectionTTL    = 10 * time.Minute
	defaultBotExtensionInputTTL        = 10 * time.Minute
	defaultBotExtensionMaxTokens       = 512
	defaultBotExtensionMaxInputs       = 64
	defaultBotExtensionMaxPayloadBytes = 12 << 20
	defaultBotExtensionMaxStateBytes   = 32 << 20

	maxBotExtensionKindBytes   = 64
	maxBotExtensionFieldBytes  = 4096
	maxBotExtensionDigestBytes = 256
	maxBotExtensionStringBytes = 64 << 10
	botExtensionTokenAttempts  = 8
)

var (
	errBotExtensionStateFull       = errors.New("bot extension conversational state is full")
	errBotExtensionPayloadTooLarge = errors.New("bot extension state payload is too large")
)

// botExtensionPayloadKind identifies the exact selection or mutation represented
// by a short-lived token. Callers may add package-local typed constants as new
// workflows are introduced; the store rejects empty, oversized, or invalid UTF-8
// kinds.
type botExtensionPayloadKind string

const (
	botExtensionPayloadMarketplaceSource  botExtensionPayloadKind = "marketplace-source"
	botExtensionPayloadMarketplaceEntry   botExtensionPayloadKind = "marketplace-entry"
	botExtensionPayloadMarketplaceAdd     botExtensionPayloadKind = "marketplace-add"
	botExtensionPayloadMarketplaceDelete  botExtensionPayloadKind = "marketplace-delete"
	botExtensionPayloadMarketplaceRefresh botExtensionPayloadKind = "marketplace-refresh"
	botExtensionPayloadModule             botExtensionPayloadKind = "module"
	botExtensionPayloadInstall            botExtensionPayloadKind = "install"
	botExtensionPayloadUninstall          botExtensionPayloadKind = "uninstall"
	botExtensionPayloadEnable             botExtensionPayloadKind = "enable"
	botExtensionPayloadDisable            botExtensionPayloadKind = "disable"
	botExtensionPayloadUpdate             botExtensionPayloadKind = "update"
	botExtensionPayloadSetting            botExtensionPayloadKind = "setting"
	botExtensionPayloadEgress             botExtensionPayloadKind = "egress"
	botExtensionPayloadCaptureDNS         botExtensionPayloadKind = "capture-dns"
	botExtensionPayloadReorder            botExtensionPayloadKind = "reorder"
)

// botExtensionStatePayload is a typed, closure-free description of a pending
// selection or mutation. RawJSON is deliberately treated as opaque bytes: it
// may contain a complete settings document, an execution order, or a local
// manifest. Every stored and returned payload owns its RawJSON backing array.
//
// Revision is the primary CAS revision. ModuleRevision is available to flows
// such as marketplace installation that must bind both marketplace and module
// state. Digest binds the current source or installed immutable snapshot;
// CandidateDigest independently binds a reviewed install or update candidate.
type botExtensionStatePayload struct {
	Kind            botExtensionPayloadKind
	Revision        string
	ModuleRevision  string
	ModuleID        string
	SourceID        string
	EntryID         string
	SettingKey      string
	Digest          string
	CandidateDigest string
	BoolValue       bool
	StringValue     string
	RawJSON         json.RawMessage
}

type botExtensionInputKind string

const (
	botExtensionInputMarketplaceURL  botExtensionInputKind = "marketplace-url"
	botExtensionInputMarketplaceName botExtensionInputKind = "marketplace-name"
	botExtensionInputModuleURL       botExtensionInputKind = "module-url"
	botExtensionInputLocalYAML       botExtensionInputKind = "local-yaml"
	botExtensionInputSettingText     botExtensionInputKind = "setting-text"
	botExtensionInputSettingNumber   botExtensionInputKind = "setting-number"
	botExtensionInputSettingLocation botExtensionInputKind = "setting-location"
)

// botExtensionInputState describes the next conversational message expected
// from one administrator in one private chat. It is ephemeral coordination,
// never authoritative extension or marketplace state.
type botExtensionInputState struct {
	Kind      botExtensionInputKind
	Payload   botExtensionStatePayload
	ExpiresAt time.Time
}

type botExtensionStateOwner struct {
	adminID int64
	chatID  int64
}

type botExtensionTokenPurpose uint8

const (
	botExtensionTokenConfirmation botExtensionTokenPurpose = iota + 1
	botExtensionTokenSelection
)

type botExtensionTokenEntry struct {
	purpose    botExtensionTokenPurpose
	owner      botExtensionStateOwner
	payload    botExtensionStatePayload
	generation uint64
	expiresAt  time.Time
	bytes      int
}

type botExtensionInputEntry struct {
	state botExtensionInputState
	bytes int
}

type botExtensionGenerationEntry struct {
	value     uint64
	expiresAt time.Time
	active    bool
}

type botExtensionStateStoreOptions struct {
	now             func() time.Time
	entropy         io.Reader
	confirmationTTL time.Duration
	selectionTTL    time.Duration
	inputTTL        time.Duration
	maxTokens       int
	maxInputs       int
	maxPayloadBytes int
	maxStateBytes   int
}

// botExtensionStateStore holds only bounded, short-lived Telegram conversation
// state. Mutations must still re-read the in-process manager and validate the
// payload's revision and digest before applying anything.
type botExtensionStateStore struct {
	mu sync.Mutex

	tokens      map[string]botExtensionTokenEntry
	inputs      map[botExtensionStateOwner]botExtensionInputEntry
	generations map[botExtensionStateOwner]botExtensionGenerationEntry

	now             func() time.Time
	entropy         io.Reader
	confirmationTTL time.Duration
	selectionTTL    time.Duration
	inputTTL        time.Duration
	maxTokens       int
	maxInputs       int
	maxPayloadBytes int
	maxStateBytes   int
	usedBytes       int
	nextGeneration  uint64
}

func newBotExtensionStateStore() *botExtensionStateStore {
	return newBotExtensionStateStoreWithOptions(botExtensionStateStoreOptions{})
}

func newBotExtensionStateStoreWithOptions(options botExtensionStateStoreOptions) *botExtensionStateStore {
	s := &botExtensionStateStore{
		now:             options.now,
		entropy:         options.entropy,
		confirmationTTL: options.confirmationTTL,
		selectionTTL:    options.selectionTTL,
		inputTTL:        options.inputTTL,
		maxTokens:       options.maxTokens,
		maxInputs:       options.maxInputs,
		maxPayloadBytes: options.maxPayloadBytes,
		maxStateBytes:   options.maxStateBytes,
	}
	s.mu.Lock()
	s.initLocked()
	s.mu.Unlock()
	return s
}

func (s *botExtensionStateStore) initLocked() {
	if s.tokens == nil {
		s.tokens = make(map[string]botExtensionTokenEntry)
	}
	if s.inputs == nil {
		s.inputs = make(map[botExtensionStateOwner]botExtensionInputEntry)
	}
	if s.generations == nil {
		s.generations = make(map[botExtensionStateOwner]botExtensionGenerationEntry)
	}
	if s.now == nil {
		s.now = time.Now
	}
	if s.entropy == nil {
		s.entropy = rand.Reader
	}
	if s.confirmationTTL <= 0 {
		s.confirmationTTL = defaultBotExtensionConfirmationTTL
	}
	if s.selectionTTL <= 0 {
		s.selectionTTL = defaultBotExtensionSelectionTTL
	}
	if s.inputTTL <= 0 {
		s.inputTTL = defaultBotExtensionInputTTL
	}
	if s.maxTokens <= 0 {
		s.maxTokens = defaultBotExtensionMaxTokens
	}
	if s.maxInputs <= 0 {
		s.maxInputs = defaultBotExtensionMaxInputs
	}
	if s.maxPayloadBytes <= 0 {
		s.maxPayloadBytes = defaultBotExtensionMaxPayloadBytes
	}
	if s.maxStateBytes <= 0 {
		s.maxStateBytes = defaultBotExtensionMaxStateBytes
	}
	if s.maxPayloadBytes > s.maxStateBytes {
		s.maxPayloadBytes = s.maxStateBytes
	}
}

func (s *botExtensionStateStore) pruneLocked(now time.Time) {
	for token, entry := range s.tokens {
		if !now.Before(entry.expiresAt) {
			s.deleteTokenLocked(token, entry)
		}
	}
	for owner, entry := range s.inputs {
		if !now.Before(entry.state.ExpiresAt) {
			s.deleteInputLocked(owner, entry)
		}
	}
	for owner, entry := range s.generations {
		if !now.Before(entry.expiresAt) {
			delete(s.generations, owner)
		}
	}
}

func (s *botExtensionStateStore) advanceGenerationLocked(owner botExtensionStateOwner, now time.Time) (uint64, error) {
	entry, exists := s.generations[owner]
	if !exists && len(s.generations) >= s.maxTokens {
		return 0, errBotExtensionStateFull
	}
	s.nextGeneration++
	if s.nextGeneration == 0 {
		s.nextGeneration++
	}
	entry.value = s.nextGeneration
	entry.expiresAt = now.Add(s.selectionTTL)
	entry.active = false
	s.generations[owner] = entry
	return entry.value, nil
}

func (s *botExtensionStateStore) deleteTokenLocked(token string, entry botExtensionTokenEntry) {
	delete(s.tokens, token)
	s.releaseBytesLocked(entry.bytes)
}

func (s *botExtensionStateStore) deleteInputLocked(owner botExtensionStateOwner, entry botExtensionInputEntry) {
	delete(s.inputs, owner)
	s.releaseBytesLocked(entry.bytes)
}

func (s *botExtensionStateStore) releaseBytesLocked(count int) {
	s.usedBytes -= count
	if s.usedBytes < 0 {
		// Defensive repair: all mutations are serialized and should keep exact
		// accounting, but never let an internal inconsistency remove the bound.
		s.usedBytes = 0
	}
}

func (s *botExtensionStateStore) IssueConfirmation(adminID, chatID int64, payload botExtensionStatePayload) (string, time.Time, error) {
	return s.issueToken(botExtensionTokenConfirmation, adminID, chatID, payload)
}

func (s *botExtensionStateStore) IssueSelection(adminID, chatID int64, payload botExtensionStatePayload) (string, time.Time, error) {
	return s.issueToken(botExtensionTokenSelection, adminID, chatID, payload)
}

func (s *botExtensionStateStore) issueToken(purpose botExtensionTokenPurpose, adminID, chatID int64, payload botExtensionStatePayload) (string, time.Time, error) {
	owner, err := newBotExtensionStateOwner(adminID, chatID)
	if err != nil {
		return "", time.Time{}, err
	}
	payloadBytes, err := validateBotExtensionPayload(payload)
	if err != nil {
		return "", time.Time{}, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.initLocked()
	now := s.now()
	s.pruneLocked(now)
	if payloadBytes > s.maxPayloadBytes {
		return "", time.Time{}, errBotExtensionPayloadTooLarge
	}

	token, err := s.newTokenLocked()
	if err != nil {
		return "", time.Time{}, err
	}

	var replaced []string
	freedBytes := 0
	if purpose == botExtensionTokenConfirmation {
		for existingToken, entry := range s.tokens {
			if entry.purpose == purpose && entry.owner == owner && entry.payload.Kind == payload.Kind {
				replaced = append(replaced, existingToken)
				freedBytes += entry.bytes
			}
		}
	}
	if len(s.tokens)-len(replaced) >= s.maxTokens || s.usedBytes-freedBytes+payloadBytes > s.maxStateBytes {
		return "", time.Time{}, errBotExtensionStateFull
	}
	for _, existingToken := range replaced {
		s.deleteTokenLocked(existingToken, s.tokens[existingToken])
	}

	ttl := s.selectionTTL
	if purpose == botExtensionTokenConfirmation {
		ttl = s.confirmationTTL
	}
	expiresAt := now.Add(ttl)
	s.tokens[token] = botExtensionTokenEntry{
		purpose:   purpose,
		owner:     owner,
		payload:   cloneBotExtensionPayload(payload),
		expiresAt: expiresAt,
		bytes:     payloadBytes,
	}
	s.usedBytes += payloadBytes
	return token, expiresAt, nil
}

func (s *botExtensionStateStore) newTokenLocked() (string, error) {
	for attempt := 0; attempt < botExtensionTokenAttempts; attempt++ {
		raw := make([]byte, botExtensionTokenBytes)
		if _, err := io.ReadFull(s.entropy, raw); err != nil {
			return "", fmt.Errorf("generate bot extension token: %w", err)
		}
		token := base64.RawURLEncoding.EncodeToString(raw)
		if _, exists := s.tokens[token]; !exists {
			return token, nil
		}
	}
	return "", errors.New("generate bot extension token: repeated collision")
}

// ConsumeConfirmation returns and deletes exactly one matching confirmation.
// Owner, purpose, or kind mismatches do not burn the real owner's ticket.
func (s *botExtensionStateStore) ConsumeConfirmation(token string, adminID, chatID int64, expectedKind botExtensionPayloadKind) (botExtensionStatePayload, bool) {
	return s.tokenPayload(token, botExtensionTokenConfirmation, adminID, chatID, expectedKind, true)
}

// ResolveSelection validates a selection without consuming it, allowing a
// short-lived menu button to be revisited by its owner.
func (s *botExtensionStateStore) ResolveSelection(token string, adminID, chatID int64, expectedKind botExtensionPayloadKind) (botExtensionStatePayload, bool) {
	return s.tokenPayload(token, botExtensionTokenSelection, adminID, chatID, expectedKind, false)
}

// ConsumeSelection is available for selection steps that must themselves be
// one-use. Most read-only navigation should use ResolveSelection.
func (s *botExtensionStateStore) ConsumeSelection(token string, adminID, chatID int64, expectedKind botExtensionPayloadKind) (botExtensionStatePayload, bool) {
	return s.tokenPayload(token, botExtensionTokenSelection, adminID, chatID, expectedKind, true)
}

func (s *botExtensionStateStore) tokenPayload(token string, purpose botExtensionTokenPurpose, adminID, chatID int64, expectedKind botExtensionPayloadKind, consume bool) (botExtensionStatePayload, bool) {
	owner, err := newBotExtensionStateOwner(adminID, chatID)
	if err != nil || !validBotExtensionToken(token) || !validBotExtensionPayloadKind(expectedKind) {
		return botExtensionStatePayload{}, false
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.initLocked()
	now := s.now()
	s.pruneLocked(now)
	entry, ok := s.tokens[token]
	if !ok || entry.purpose != purpose || entry.owner != owner || entry.payload.Kind != expectedKind {
		return botExtensionStatePayload{}, false
	}
	if purpose == botExtensionTokenConfirmation && entry.generation != 0 {
		generation, current := s.generations[owner]
		if !current || generation.value != entry.generation {
			return botExtensionStatePayload{}, false
		}
	}
	payload := cloneBotExtensionPayload(entry.payload)
	if consume {
		s.deleteTokenLocked(token, entry)
	}
	return payload, true
}

func (s *botExtensionStateStore) CancelConfirmation(token string, adminID, chatID int64) bool {
	return s.cancelToken(token, botExtensionTokenConfirmation, adminID, chatID)
}

func (s *botExtensionStateStore) CancelSelection(token string, adminID, chatID int64) bool {
	return s.cancelToken(token, botExtensionTokenSelection, adminID, chatID)
}

func (s *botExtensionStateStore) cancelToken(token string, purpose botExtensionTokenPurpose, adminID, chatID int64) bool {
	owner, err := newBotExtensionStateOwner(adminID, chatID)
	if err != nil || !validBotExtensionToken(token) {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.initLocked()
	s.pruneLocked(s.now())
	entry, ok := s.tokens[token]
	if !ok || entry.purpose != purpose || entry.owner != owner {
		return false
	}
	s.deleteTokenLocked(token, entry)
	return true
}

func (s *botExtensionStateStore) BeginInput(adminID, chatID int64, kind botExtensionInputKind, payload botExtensionStatePayload) (time.Time, error) {
	owner, err := newBotExtensionStateOwner(adminID, chatID)
	if err != nil {
		return time.Time{}, err
	}
	if !validBotExtensionInputKind(kind) {
		return time.Time{}, fmt.Errorf("unsupported bot extension input kind %q", kind)
	}
	payloadBytes, err := validateBotExtensionPayload(payload)
	if err != nil {
		return time.Time{}, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.initLocked()
	now := s.now()
	s.pruneLocked(now)
	if payloadBytes > s.maxPayloadBytes {
		return time.Time{}, errBotExtensionPayloadTooLarge
	}
	previous, replacing := s.inputs[owner]
	previousBytes := 0
	if replacing {
		previousBytes = previous.bytes
	}
	if (!replacing && len(s.inputs) >= s.maxInputs) || s.usedBytes-previousBytes+payloadBytes > s.maxStateBytes {
		return time.Time{}, errBotExtensionStateFull
	}
	if replacing {
		s.deleteInputLocked(owner, previous)
	}
	expiresAt := now.Add(s.inputTTL)
	s.inputs[owner] = botExtensionInputEntry{
		state: botExtensionInputState{
			Kind:      kind,
			Payload:   cloneBotExtensionPayload(payload),
			ExpiresAt: expiresAt,
		},
		bytes: payloadBytes,
	}
	s.usedBytes += payloadBytes
	return expiresAt, nil
}

func (s *botExtensionStateStore) Input(adminID, chatID int64) (botExtensionInputState, bool) {
	owner, err := newBotExtensionStateOwner(adminID, chatID)
	if err != nil {
		return botExtensionInputState{}, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.initLocked()
	s.pruneLocked(s.now())
	entry, ok := s.inputs[owner]
	if !ok {
		return botExtensionInputState{}, false
	}
	return cloneBotExtensionInputState(entry.state), true
}

// ConsumeInput atomically takes a matching conversation state. A kind mismatch
// leaves it intact so an unrelated Telegram update cannot cancel the flow.
func (s *botExtensionStateStore) ConsumeInput(adminID, chatID int64, expectedKind botExtensionInputKind) (botExtensionStatePayload, bool) {
	owner, err := newBotExtensionStateOwner(adminID, chatID)
	if err != nil || !validBotExtensionInputKind(expectedKind) {
		return botExtensionStatePayload{}, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.initLocked()
	now := s.now()
	s.pruneLocked(now)
	_, _ = s.advanceGenerationLocked(owner, now)
	entry, ok := s.inputs[owner]
	if !ok || entry.state.Kind != expectedKind {
		return botExtensionStatePayload{}, false
	}
	payload := cloneBotExtensionPayload(entry.state.Payload)
	s.deleteInputLocked(owner, entry)
	return payload, true
}

func (s *botExtensionStateStore) CancelInput(adminID, chatID int64) bool {
	owner, err := newBotExtensionStateOwner(adminID, chatID)
	if err != nil {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.initLocked()
	now := s.now()
	s.pruneLocked(now)
	_, _ = s.advanceGenerationLocked(owner, now)
	entry, ok := s.inputs[owner]
	if !ok {
		return false
	}
	s.deleteInputLocked(owner, entry)
	return true
}

// CancelOwner clears every ephemeral plugin token and input belonging to one
// administrator/private-chat pair. It is intended for /cancel and menu resets.
func (s *botExtensionStateStore) CancelOwner(adminID, chatID int64) bool {
	removed, _ := s.CancelOwnerWithGeneration(adminID, chatID)
	return removed
}

// CancelOwnerWithGeneration invalidates all existing owner state and returns
// the new generation as a cutoff for cancelling only operations that began
// before this cancellation. A later operation receives a greater generation
// and must survive cleanup of the earlier request.
func (s *botExtensionStateStore) CancelOwnerWithGeneration(adminID, chatID int64) (bool, uint64) {
	owner, err := newBotExtensionStateOwner(adminID, chatID)
	if err != nil {
		return false, 0
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.initLocked()
	now := s.now()
	s.pruneLocked(now)
	generation := s.generations[owner]
	cutoff, _ := s.advanceGenerationLocked(owner, now)
	removed := generation.active
	for token, entry := range s.tokens {
		if entry.owner == owner {
			s.deleteTokenLocked(token, entry)
			removed = true
		}
	}
	if entry, ok := s.inputs[owner]; ok {
		s.deleteInputLocked(owner, entry)
		removed = true
	}
	return removed, cutoff
}

func newBotExtensionStateOwner(adminID, chatID int64) (botExtensionStateOwner, error) {
	if adminID <= 0 || chatID <= 0 {
		return botExtensionStateOwner{}, errors.New("bot extension state requires a positive admin and private chat id")
	}
	return botExtensionStateOwner{adminID: adminID, chatID: chatID}, nil
}

func validBotExtensionToken(token string) bool {
	if len(token) != base64.RawURLEncoding.EncodedLen(botExtensionTokenBytes) {
		return false
	}
	raw, err := base64.RawURLEncoding.DecodeString(token)
	return err == nil && len(raw) == botExtensionTokenBytes
}

func validBotExtensionPayloadKind(kind botExtensionPayloadKind) bool {
	return kind != "" && len(kind) <= maxBotExtensionKindBytes && utf8.ValidString(string(kind))
}

func validBotExtensionInputKind(kind botExtensionInputKind) bool {
	switch kind {
	case botExtensionInputMarketplaceURL,
		botExtensionInputMarketplaceName,
		botExtensionInputModuleURL,
		botExtensionInputLocalYAML,
		botExtensionInputSettingText,
		botExtensionInputSettingNumber,
		botExtensionInputSettingLocation:
		return true
	default:
		return false
	}
}

func validateBotExtensionPayload(payload botExtensionStatePayload) (int, error) {
	if !validBotExtensionPayloadKind(payload.Kind) {
		return 0, fmt.Errorf("invalid bot extension payload kind %q", payload.Kind)
	}
	fields := []struct {
		name  string
		value string
		limit int
	}{
		{name: "revision", value: payload.Revision, limit: maxBotExtensionFieldBytes},
		{name: "module revision", value: payload.ModuleRevision, limit: maxBotExtensionFieldBytes},
		{name: "module id", value: payload.ModuleID, limit: maxBotExtensionFieldBytes},
		{name: "source id", value: payload.SourceID, limit: maxBotExtensionFieldBytes},
		{name: "entry id", value: payload.EntryID, limit: maxBotExtensionFieldBytes},
		{name: "setting key", value: payload.SettingKey, limit: maxBotExtensionFieldBytes},
		{name: "digest", value: payload.Digest, limit: maxBotExtensionDigestBytes},
		{name: "candidate digest", value: payload.CandidateDigest, limit: maxBotExtensionDigestBytes},
		{name: "string value", value: payload.StringValue, limit: maxBotExtensionStringBytes},
	}
	size := len(payload.Kind) + len(payload.RawJSON)
	for _, field := range fields {
		if len(field.value) > field.limit || !utf8.ValidString(field.value) {
			return 0, fmt.Errorf("invalid bot extension payload %s", field.name)
		}
		size += len(field.value)
	}
	return size, nil
}

func cloneBotExtensionPayload(payload botExtensionStatePayload) botExtensionStatePayload {
	clone := payload
	clone.RawJSON = append(json.RawMessage(nil), payload.RawJSON...)
	return clone
}

func cloneBotExtensionInputState(state botExtensionInputState) botExtensionInputState {
	clone := state
	clone.Payload = cloneBotExtensionPayload(state.Payload)
	return clone
}
