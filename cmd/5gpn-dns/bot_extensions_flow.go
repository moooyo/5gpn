package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"strings"
	"time"

	"github.com/go-telegram/bot"
	"github.com/go-telegram/bot/models"
)

type botExtensionOperationContextKey struct{}

type botExtensionOperationContext struct {
	owner      botExtensionStateOwner
	generation uint64
}

func withBotExtensionOperation(ctx context.Context, owner botExtensionStateOwner, generation uint64) context.Context {
	return context.WithValue(ctx, botExtensionOperationContextKey{}, botExtensionOperationContext{owner: owner, generation: generation})
}

func botExtensionOperationFromContext(ctx context.Context) (botExtensionOperationContext, bool) {
	operation, ok := ctx.Value(botExtensionOperationContextKey{}).(botExtensionOperationContext)
	return operation, ok && operation.generation != 0
}

func (s *botExtensionStateStore) BeginOperation(adminID, chatID int64) (botExtensionStateOwner, uint64, error) {
	owner, err := newBotExtensionStateOwner(adminID, chatID)
	if err != nil {
		return owner, 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.initLocked()
	now := s.now()
	s.pruneLocked(now)
	if entry, ok := s.inputs[owner]; ok {
		s.deleteInputLocked(owner, entry)
	}
	generation, err := s.advanceGenerationLocked(owner, now)
	if err == nil {
		entry := s.generations[owner]
		entry.active = true
		s.generations[owner] = entry
	}
	return owner, generation, err
}

func (s *botExtensionStateStore) ClaimInput(adminID, chatID int64) (botExtensionInputState, botExtensionStateOwner, uint64, bool) {
	owner, err := newBotExtensionStateOwner(adminID, chatID)
	if err != nil {
		return botExtensionInputState{}, owner, 0, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.initLocked()
	now := s.now()
	s.pruneLocked(now)
	entry, ok := s.inputs[owner]
	if !ok {
		return botExtensionInputState{}, owner, 0, false
	}
	generation, err := s.advanceGenerationLocked(owner, now)
	if err != nil {
		return botExtensionInputState{}, owner, 0, false
	}
	generationEntry := s.generations[owner]
	generationEntry.active = true
	s.generations[owner] = generationEntry
	state := cloneBotExtensionInputState(entry.state)
	s.deleteInputLocked(owner, entry)
	return state, owner, generation, true
}

func (s *botExtensionStateStore) FinishOperation(operation botExtensionOperationContext) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.initLocked()
	s.pruneLocked(s.now())
	entry, ok := s.generations[operation.owner]
	if !ok || entry.value != operation.generation {
		return
	}
	entry.active = false
	s.generations[operation.owner] = entry
}

func (s *botExtensionStateStore) OperationCurrent(operation botExtensionOperationContext) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.initLocked()
	s.pruneLocked(s.now())
	entry, ok := s.generations[operation.owner]
	return ok && entry.value == operation.generation
}

func (bt *Bot) botExtensionOperationCurrent(ctx context.Context) bool {
	operation, ok := botExtensionOperationFromContext(ctx)
	return !ok || bt.extensionStateStore().OperationCurrent(operation)
}

func (s *botExtensionStateStore) BeginInputForOperation(
	ctx context.Context,
	kind botExtensionInputKind,
	payload botExtensionStatePayload,
) (time.Time, error) {
	operation, ok := botExtensionOperationFromContext(ctx)
	if !ok || !validBotExtensionInputKind(kind) {
		return time.Time{}, errors.New("extension operation is no longer current")
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
	generation, current := s.generations[operation.owner]
	if !current || generation.value != operation.generation {
		return time.Time{}, errors.New("extension operation was cancelled")
	}
	previous, replacing := s.inputs[operation.owner]
	previousBytes := 0
	if replacing {
		previousBytes = previous.bytes
	}
	if payloadBytes > s.maxPayloadBytes || (!replacing && len(s.inputs) >= s.maxInputs) || s.usedBytes-previousBytes+payloadBytes > s.maxStateBytes {
		return time.Time{}, errBotExtensionStateFull
	}
	if replacing {
		s.deleteInputLocked(operation.owner, previous)
	}
	expiresAt := now.Add(s.inputTTL)
	s.inputs[operation.owner] = botExtensionInputEntry{
		state: botExtensionInputState{Kind: kind, Payload: cloneBotExtensionPayload(payload), ExpiresAt: expiresAt},
		bytes: payloadBytes,
	}
	s.usedBytes += payloadBytes
	return expiresAt, nil
}

func (s *botExtensionStateStore) IssueConfirmationForOperation(
	ctx context.Context,
	payload botExtensionStatePayload,
) (string, time.Time, error) {
	operation, ok := botExtensionOperationFromContext(ctx)
	if !ok {
		return "", time.Time{}, errors.New("extension operation context is missing")
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
	generation, current := s.generations[operation.owner]
	if !current || generation.value != operation.generation {
		return "", time.Time{}, errors.New("extension operation was cancelled")
	}
	if payloadBytes > s.maxPayloadBytes {
		return "", time.Time{}, errBotExtensionPayloadTooLarge
	}
	token, err := s.newTokenLocked()
	if err != nil {
		return "", time.Time{}, err
	}
	var replaced []string
	freedBytes := 0
	for existingToken, entry := range s.tokens {
		if entry.purpose == botExtensionTokenConfirmation && entry.owner == operation.owner && entry.payload.Kind == payload.Kind {
			replaced = append(replaced, existingToken)
			freedBytes += entry.bytes
		}
	}
	if len(s.tokens)-len(replaced) >= s.maxTokens || s.usedBytes-freedBytes+payloadBytes > s.maxStateBytes {
		return "", time.Time{}, errBotExtensionStateFull
	}
	for _, existingToken := range replaced {
		s.deleteTokenLocked(existingToken, s.tokens[existingToken])
	}
	expiresAt := now.Add(s.confirmationTTL)
	s.tokens[token] = botExtensionTokenEntry{
		purpose:    botExtensionTokenConfirmation,
		owner:      operation.owner,
		payload:    cloneBotExtensionPayload(payload),
		generation: operation.generation,
		expiresAt:  expiresAt,
		bytes:      payloadBytes,
	}
	s.usedBytes += payloadBytes
	return token, expiresAt, nil
}

func (s *botExtensionStateStore) IssueSelectionForOperation(
	ctx context.Context,
	payload botExtensionStatePayload,
) (string, time.Time, error) {
	operation, ok := botExtensionOperationFromContext(ctx)
	if !ok {
		return "", time.Time{}, errors.New("extension operation context is missing")
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
	generation, current := s.generations[operation.owner]
	if !current || generation.value != operation.generation {
		return "", time.Time{}, errors.New("extension operation was cancelled")
	}
	if payloadBytes > s.maxPayloadBytes || len(s.tokens) >= s.maxTokens || s.usedBytes+payloadBytes > s.maxStateBytes {
		return "", time.Time{}, errBotExtensionStateFull
	}
	token, err := s.newTokenLocked()
	if err != nil {
		return "", time.Time{}, err
	}
	expiresAt := now.Add(s.selectionTTL)
	s.tokens[token] = botExtensionTokenEntry{
		purpose: botExtensionTokenSelection, owner: operation.owner,
		payload: cloneBotExtensionPayload(payload), expiresAt: expiresAt, bytes: payloadBytes,
	}
	s.usedBytes += payloadBytes
	return token, expiresAt, nil
}

func (s *botExtensionStateStore) CancelSelectionsByKindForOperation(
	ctx context.Context,
	kind botExtensionPayloadKind,
) (bool, error) {
	operation, ok := botExtensionOperationFromContext(ctx)
	if !ok || !validBotExtensionPayloadKind(kind) {
		return false, errors.New("extension operation context is missing")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.initLocked()
	s.pruneLocked(s.now())
	generation, current := s.generations[operation.owner]
	if !current || generation.value != operation.generation {
		return false, errors.New("extension operation was cancelled")
	}
	removed := false
	for token, entry := range s.tokens {
		if entry.owner == operation.owner && entry.purpose == botExtensionTokenSelection && entry.payload.Kind == kind {
			s.deleteTokenLocked(token, entry)
			removed = true
		}
	}
	return removed, nil
}

func (bt *Bot) beginBotExtensionImport(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	kind botExtensionInputKind,
) {
	view, err := bt.ctrl.InterceptModules()
	if err != nil {
		bt.edit(ctx, b, cq, "❌ 插件状态不可用："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	if kind != botExtensionInputModuleURL && kind != botExtensionInputLocalYAML {
		bt.edit(ctx, b, cq, "安装输入类型无效。", botExtensionBack("modules"))
		return
	}
	_, err = bt.extensionStateStore().BeginInputForOperation(ctx, kind, botExtensionStatePayload{
		Kind:     botExtensionPayloadInstall,
		Revision: view.Revision,
	})
	if err != nil {
		bt.edit(ctx, b, cq, "❌ 无法开始安装输入："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	prompt := "请发送一个明确的 <code>https://</code> 原生插件 manifest URL。"
	if kind == botExtensionInputLocalYAML {
		prompt = "请直接粘贴一份完整的 <code>5gpn.io/v1</code> YAML manifest 文本。\n本地 manifest 的脚本只能使用 inline source 或绝对 HTTPS URL。"
	}
	bt.edit(ctx, b, cq, prompt+"\n机器人会先解析不可变候选快照，再显示完整审查；发送 /cancel 可取消。", botExtensionBack("modules"))
}

func (bt *Bot) handleExtensionInput(
	ctx context.Context,
	b *bot.Bot,
	update *models.Update,
	uid int64,
) bool {
	if update == nil || update.Message == nil || uid <= 0 {
		return false
	}
	chatID := update.Message.Chat.ID
	state, owner, generation, ok := bt.extensionStateStore().ClaimInput(uid, chatID)
	if !ok {
		return false
	}
	ctx = withBotExtensionOperation(ctx, owner, generation)
	var finish func()
	ctx, finish = bt.startBotExtensionOperation(ctx, owner, generation)
	defer finish()
	releaseRender, err := bt.acquireBotExtensionRender(ctx)
	if err != nil {
		return true
	}
	defer releaseRender()
	payload := state.Payload

	switch state.Kind {
	case botExtensionInputMarketplaceURL:
		bt.consumeBotExtensionMarketplaceURL(ctx, b, chatID, uid, payload, update.Message.Text)
	case botExtensionInputMarketplaceName:
		bt.consumeBotExtensionMarketplaceName(ctx, b, chatID, uid, payload, update.Message.Text)
	case botExtensionInputModuleURL:
		bt.consumeBotExtensionImport(ctx, b, chatID, uid, payload, "url", update.Message.Text)
	case botExtensionInputLocalYAML:
		bt.consumeBotExtensionImport(ctx, b, chatID, uid, payload, "local", update.Message.Text)
	case botExtensionInputSettingText, botExtensionInputSettingNumber, botExtensionInputSettingLocation:
		bt.consumeBotExtensionSettingInput(ctx, b, chatID, uid, state.Kind, payload, update.Message)
	default:
		bt.send(ctx, b, chatID, "输入状态无效，已安全取消。", botExtensionBack("modules"))
	}
	return true
}

func (bt *Bot) retryBotExtensionInput(
	ctx context.Context,
	b *bot.Bot,
	chatID int64,
	kind botExtensionInputKind,
	payload botExtensionStatePayload,
	message string,
) {
	if !bt.botExtensionOperationCurrent(ctx) {
		return
	}
	if _, err := bt.extensionStateStore().BeginInputForOperation(ctx, kind, payload); err != nil {
		bt.send(ctx, b, chatID, message+"\n❌ 无法继续等待输入："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	bt.send(ctx, b, chatID, message+"\n请重试，或发送 /cancel 取消。", botExtensionBack("modules"))
}

func (bt *Bot) consumeBotExtensionMarketplaceURL(
	ctx context.Context,
	b *bot.Bot,
	chatID, uid int64,
	payload botExtensionStatePayload,
	input string,
) {
	rawURL := strings.TrimSpace(input)
	if !strings.HasPrefix(rawURL, "https://") || len(rawURL) > maxInterceptResourceURL {
		bt.retryBotExtensionInput(ctx, b, chatID, botExtensionInputMarketplaceURL, payload,
			"❌ 市场索引必须是长度受限的明确 HTTPS URL。")
		return
	}
	payload.StringValue = rawURL
	if _, err := bt.extensionStateStore().BeginInputForOperation(ctx, botExtensionInputMarketplaceName, payload); err != nil {
		bt.send(ctx, b, chatID, "❌ 无法继续市场添加流程："+pre(err.Error()), botExtensionBack("market"))
		return
	}
	bt.send(ctx, b, chatID,
		"请发送这个来源的本地显示名称；发送单个 <code>-</code> 使用远端市场名称。\n显示名称只用于本地界面，不代表或认证发布者身份。",
		botExtensionBack("market"))
}

func (bt *Bot) consumeBotExtensionMarketplaceName(
	ctx context.Context,
	b *bot.Bot,
	chatID, uid int64,
	payload botExtensionStatePayload,
	input string,
) {
	name := strings.TrimSpace(input)
	if name == "-" {
		name = ""
	}
	if len(name) > maxMarketplaceDisplayName {
		bt.retryBotExtensionInput(ctx, b, chatID, botExtensionInputMarketplaceName, payload,
			fmt.Sprintf("❌ 本地显示名称不能超过 %d bytes。", maxMarketplaceDisplayName))
		return
	}
	current, err := bt.ctrl.ExtensionMarketplaces()
	if err != nil || current.Revision != payload.Revision {
		if err == nil {
			err = errMarketplaceRevision
		}
		bt.send(ctx, b, chatID, "⚠️ 市场状态已变化，请重新开始："+pre(err.Error()), botExtensionBack("market"))
		return
	}
	release, err := bt.acquireBotExtensionFetch(ctx)
	if err != nil {
		return
	}
	candidate, err := bt.ctrl.PreviewExtensionMarketplaceAdd(ctx, payload.StringValue, name)
	release()
	if err != nil {
		bt.send(ctx, b, chatID, "❌ 市场索引验证失败，未创建确认："+pre(err.Error()), botExtensionBack("market"))
		return
	}
	raw, err := marshalBotExtensionMutation(botExtensionMutation{URL: payload.StringValue, Name: name})
	if err != nil {
		bt.send(ctx, b, chatID, "❌ 无法准备市场确认："+pre(err.Error()), botExtensionBack("market"))
		return
	}
	confirmation := botExtensionStatePayload{
		Kind:     botExtensionPayloadMarketplaceAdd,
		Revision: payload.Revision,
		SourceID: candidate.ID,
		Digest:   candidate.SnapshotDigest,
		RawJSON:  raw,
	}
	prompt := "⚠️ <b>确认添加插件市场来源？</b>\n" + marketplaceSourceReviewHTML(candidate) +
		"\n\n远端名称和描述来自索引；本地显示名称只是别名，两者都不代表发布者身份。添加不会自动安装或启用插件。"
	bt.sendBotExtensionConfirmation(ctx, b, uid, chatID, confirmation, prompt, "market")
}

func (bt *Bot) consumeBotExtensionImport(
	ctx context.Context,
	b *bot.Bot,
	chatID, uid int64,
	payload botExtensionStatePayload,
	mode, input string,
) {
	request := interceptModuleImportRequest{Revision: payload.Revision}
	switch mode {
	case "url":
		request.URL = strings.TrimSpace(input)
		if !strings.HasPrefix(request.URL, "https://") || len(request.URL) > maxInterceptResourceURL {
			bt.retryBotExtensionInput(ctx, b, chatID, botExtensionInputModuleURL, payload,
				"❌ 插件 manifest 必须是长度受限的明确 HTTPS URL。")
			return
		}
	case "local":
		request.Content = input
		if strings.TrimSpace(request.Content) == "" {
			bt.retryBotExtensionInput(ctx, b, chatID, botExtensionInputLocalYAML, payload,
				"❌ YAML manifest 不能为空。")
			return
		}
	default:
		bt.send(ctx, b, chatID, "安装输入模式无效。", botExtensionBack("modules"))
		return
	}
	release, err := bt.acquireBotExtensionFetch(ctx)
	if err != nil {
		return
	}
	candidate, err := bt.ctrl.PreviewInterceptModuleImport(ctx, request)
	release()
	if err != nil {
		bt.send(ctx, b, chatID, "❌ 插件候选验证失败，未创建确认："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	raw, err := marshalBotExtensionMutation(botExtensionMutation{Mode: mode, URL: request.URL, Content: request.Content})
	if err != nil {
		bt.send(ctx, b, chatID, "❌ 无法准备安装确认："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	confirmation := botExtensionStatePayload{
		Kind:            botExtensionPayloadInstall,
		Revision:        payload.Revision,
		ModuleID:        candidate.ID,
		Digest:          candidate.SnapshotDigest,
		CandidateDigest: candidate.SnapshotDigest,
		RawJSON:         raw,
	}
	prompt := "⚠️ <b>确认安装插件？</b>\n" + botExtensionCandidateReviewHTML(candidate) +
		"\n\n确认时会重新获取或重新解析同一输入，并要求候选摘要完全一致。安装后插件保持关闭，不会发布流量接管。"
	bt.sendBotExtensionConfirmation(ctx, b, uid, chatID, confirmation, prompt, "modules")
}

func (bt *Bot) consumeBotExtensionSettingInput(
	ctx context.Context,
	b *bot.Bot,
	chatID, uid int64,
	kind botExtensionInputKind,
	payload botExtensionStatePayload,
	message *models.Message,
) {
	view, module, setting, err := requireBotExtensionSetting(bt, payload)
	if err != nil {
		bt.send(ctx, b, chatID, "⚠️ 插件参数状态已变化，请重新打开参数："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	var value json.RawMessage
	if kind == botExtensionInputSettingLocation && message.Location != nil {
		value, err = botExtensionLocationValue(*message.Location)
	} else {
		if kind == botExtensionInputSettingLocation && strings.TrimSpace(message.Text) == "" {
			err = errors.New("请发送 Telegram 位置或 longitude,latitude,accuracy")
		} else {
			value, err = parseBotExtensionSettingText(setting, message.Text)
		}
	}
	if err != nil {
		bt.retryBotExtensionInput(ctx, b, chatID, kind, payload, "❌ 参数值无效："+pre(err.Error()))
		return
	}
	settings, err := buildBotExtensionSettings(module.Settings, setting.Key, value)
	if err != nil {
		bt.send(ctx, b, chatID, "❌ 无法构建完整 settings map："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	if setting.Type == "location" {
		if !bt.botExtensionOperationCurrent(ctx) {
			return
		}
		if err := sendBotExtensionLocationPreview(ctx, b, chatID, value); err != nil {
			bt.retryBotExtensionInput(ctx, b, chatID, kind, payload,
				"❌ 地图点预览未能送达，因此未创建确认："+pre(err.Error()))
			return
		}
	}
	raw, err := marshalBotExtensionMutation(botExtensionMutation{Settings: settings})
	if err != nil {
		bt.send(ctx, b, chatID, "❌ 无法准备参数确认："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	confirmation := botExtensionStatePayload{
		Kind:       botExtensionPayloadSetting,
		Revision:   view.Revision,
		ModuleID:   module.ID,
		SettingKey: setting.Key,
		Digest:     module.SnapshotDigest,
		RawJSON:    raw,
	}
	prompt := botExtensionSettingReviewHTML(module, setting, value) +
		"\n\n提交内容包含该插件的完整 settings map；其他参数保持当前值。"
	if setting.Type == "location" {
		prompt += "\n坐标已经通过 Telegram 与 Telegram Bot API，并在上方以受保护地图点预览。"
	}
	bt.sendBotExtensionConfirmation(ctx, b, uid, chatID, confirmation, prompt, "modules")
}

func sendBotExtensionLocationPreview(ctx context.Context, b *bot.Bot, chatID int64, raw json.RawMessage) error {
	var location interceptLocationValue
	if err := unmarshalStrictJSON(raw, &location); err != nil || location.Longitude == nil || location.Latitude == nil {
		return errors.New("location value is incomplete")
	}
	accuracy := float64(location.Accuracy)
	if accuracy > 1500 {
		accuracy = 0
	}
	_, err := b.SendLocation(ctx, &bot.SendLocationParams{
		ChatID:             chatID,
		Longitude:          *location.Longitude,
		Latitude:           *location.Latitude,
		HorizontalAccuracy: accuracy,
		ProtectContent:     true,
	})
	return err
}

func requireBotExtensionModule(bt *Bot, payload botExtensionStatePayload) (interceptModulesView, interceptModuleView, error) {
	view, err := bt.ctrl.InterceptModules()
	if err != nil {
		return interceptModulesView{}, interceptModuleView{}, err
	}
	if view.Revision != payload.Revision {
		return view, interceptModuleView{}, errInterceptRevisionConflict
	}
	for _, module := range view.Modules {
		if module.ID == payload.ModuleID && module.SnapshotDigest == payload.Digest {
			return view, module, nil
		}
	}
	return view, interceptModuleView{}, errors.New("extension snapshot changed since review")
}

func requireBotExtensionSetting(bt *Bot, payload botExtensionStatePayload) (interceptModulesView, interceptModuleView, interceptModuleSetting, error) {
	view, module, err := requireBotExtensionModule(bt, payload)
	if err != nil {
		return view, module, interceptModuleSetting{}, err
	}
	for _, setting := range module.Settings {
		if setting.Key == payload.SettingKey {
			return view, module, setting, nil
		}
	}
	return view, module, interceptModuleSetting{}, errors.New("extension setting changed since review")
}

func (bt *Bot) executeBotExtensionConfirmation(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	rest string,
) {
	kindRaw, token, ok := strings.Cut(rest, ":")
	kind := botExtensionPayloadKind(kindRaw)
	if !ok || !knownBotExtensionConfirmationKind(kind) || !validBotExtensionToken(token) {
		bt.edit(ctx, b, cq, "⚠️ 确认参数无效。", botExtensionBack("modules"))
		return
	}
	payload, ok := bt.extensionStateStore().ConsumeConfirmation(token, uid, chatID, kind)
	if !ok {
		bt.edit(ctx, b, cq, "⚠️ 确认已过期、已使用、类型不匹配，或不属于当前管理员与私聊。", botExtensionBack("modules"))
		return
	}
	op := "extension:" + string(payload.Kind)
	auditBot(op, uid, "invoked")
	applyCtx, cancel := context.WithTimeout(ctx, botExtensionOperationTimeout)
	defer cancel()
	var err error
	if botExtensionConfirmationFetches(payload.Kind) {
		var release func()
		release, err = bt.acquireBotExtensionFetch(applyCtx)
		if err == nil {
			err = func() error {
				defer release()
				return bt.applyBotExtensionConfirmation(applyCtx, payload)
			}()
		}
	} else {
		err = bt.applyBotExtensionConfirmation(applyCtx, payload)
	}
	auditBotOutcome(op, uid, err == nil)
	if err != nil {
		bt.edit(ctx, b, cq,
			"❌ 操作未完成；revision、snapshot 或 candidate 冲突不会自动重试："+pre(err.Error()),
			botExtensionBack("modules"))
		return
	}
	back := "modules"
	if payload.Kind == botExtensionPayloadMarketplaceAdd || payload.Kind == botExtensionPayloadMarketplaceDelete || payload.Kind == botExtensionPayloadMarketplaceRefresh {
		back = "market"
	}
	message := "✅ 操作已完成。"
	if payload.Kind == botExtensionPayloadInstall || payload.Kind == botExtensionPayloadUpdate {
		message = bt.botExtensionDisabledResultHTML(payload)
	}
	bt.edit(ctx, b, cq, message, botExtensionBack(back))
}

func botExtensionConfirmationFetches(kind botExtensionPayloadKind) bool {
	switch kind {
	case botExtensionPayloadMarketplaceAdd,
		botExtensionPayloadMarketplaceRefresh,
		botExtensionPayloadInstall,
		botExtensionPayloadUpdate:
		return true
	default:
		return false
	}
}

func (bt *Bot) botExtensionDisabledResultHTML(payload botExtensionStatePayload) string {
	view, err := bt.ctrl.InterceptModules()
	if err != nil {
		return "✅ 插件快照已提交并按事务契约保持关闭；重新打开插件列表可查看当前摘要。"
	}
	for _, module := range view.Modules {
		if module.ID != payload.ModuleID {
			continue
		}
		state := "关闭"
		if module.Enabled {
			state = "异常：已启用"
		}
		return "✅ <b>插件快照已提交</b>\n插件：<b>" + html.EscapeString(module.Name) +
			"</b> · <code>" + html.EscapeString(module.Version) + "</code>\n快照：<code>" +
			html.EscapeString(module.SnapshotDigest) + "</code>\n实际状态：<b>" + state + "</b>"
	}
	return "✅ 插件快照事务已完成；重新打开插件列表可查看实际关闭状态与摘要。"
}

func (bt *Bot) applyBotExtensionConfirmation(ctx context.Context, payload botExtensionStatePayload) error {
	mutation, mutationErr := decodeBotExtensionMutation(payload.RawJSON)
	switch payload.Kind {
	case botExtensionPayloadMarketplaceAdd:
		if mutationErr != nil {
			return mutationErr
		}
		view, err := bt.ctrl.ExtensionMarketplaces()
		if err != nil {
			return err
		}
		if view.Revision != payload.Revision {
			return errMarketplaceRevision
		}
		_, err = bt.ctrl.AddExtensionMarketplaceExpected(ctx, payload.Revision, mutation.URL, mutation.Name, payload.Digest)
		return err

	case botExtensionPayloadMarketplaceRefresh:
		if mutationErr != nil {
			return mutationErr
		}
		view, source, err := requireBotExtensionSource(bt, payload.Revision, payload.SourceID, mutation.CurrentDigest)
		if err != nil {
			return err
		}
		_, err = bt.ctrl.RefreshExtensionMarketplaceExpected(ctx, source.ID, view.Revision, payload.Digest)
		return err

	case botExtensionPayloadMarketplaceDelete:
		view, source, err := requireBotExtensionSource(bt, payload.Revision, payload.SourceID, payload.Digest)
		if err != nil {
			return err
		}
		_, err = bt.ctrl.DeleteExtensionMarketplace(ctx, source.ID, view.Revision)
		return err

	case botExtensionPayloadInstall:
		if mutationErr != nil {
			return mutationErr
		}
		return bt.applyBotExtensionInstall(ctx, payload, mutation)

	case botExtensionPayloadUninstall:
		view, module, err := requireBotExtensionModule(bt, payload)
		if err != nil {
			return err
		}
		if module.Enabled {
			return errors.New("disable the extension before uninstalling it")
		}
		_, err = bt.ctrl.DeleteInterceptModule(ctx, module.ID, view.Revision)
		return err

	case botExtensionPayloadEnable, botExtensionPayloadDisable:
		view, module, err := requireBotExtensionModule(bt, payload)
		if err != nil {
			return err
		}
		if (payload.Kind == botExtensionPayloadEnable) != payload.BoolValue {
			return errors.New("extension enable confirmation payload is inconsistent")
		}
		_, err = bt.ctrl.SetInterceptModuleEnabled(ctx, module.ID, view.Revision, payload.BoolValue)
		return err

	case botExtensionPayloadUpdate:
		view, module, err := requireBotExtensionModule(bt, payload)
		if err != nil {
			return err
		}
		if module.Enabled {
			return errors.New("disable the extension before applying an update")
		}
		if !validSHA256(payload.CandidateDigest) {
			return errors.New("confirmed update candidate digest is invalid")
		}
		_, err = bt.ctrl.ApplyInterceptModuleUpdate(ctx, module.ID, view.Revision, payload.CandidateDigest)
		return err

	case botExtensionPayloadSetting:
		if mutationErr != nil {
			return mutationErr
		}
		view, module, _, err := requireBotExtensionSetting(bt, payload)
		if err != nil {
			return err
		}
		if mutation.Settings == nil {
			return errors.New("confirmed complete settings map is missing")
		}
		_, err = bt.ctrl.UpdateInterceptModule(ctx, module.ID, interceptModuleUpdate{
			Revision: view.Revision,
			Settings: mutation.Settings,
		})
		return err

	case botExtensionPayloadEgress:
		view, module, err := requireBotExtensionModule(bt, payload)
		if err != nil {
			return err
		}
		allowed := payload.StringValue == ""
		for _, group := range view.AvailableEgressGroups {
			if group == payload.StringValue {
				allowed = true
				break
			}
		}
		if !allowed || (module.EgressGroupRequired && payload.StringValue == "") {
			return errors.New("confirmed egress group is no longer allowed")
		}
		group := payload.StringValue
		_, err = bt.ctrl.UpdateInterceptModule(ctx, module.ID, interceptModuleUpdate{
			Revision:    view.Revision,
			EgressGroup: &group,
		})
		return err

	case botExtensionPayloadCaptureDNS:
		view, module, err := requireBotExtensionModule(bt, payload)
		if err != nil {
			return err
		}
		if err := validateInterceptCaptureDNS(payload.StringValue); err != nil {
			return fmt.Errorf("confirmed capture DNS binding is invalid: %w", err)
		}
		resolver := payload.StringValue
		_, err = bt.ctrl.UpdateInterceptModule(ctx, module.ID, interceptModuleUpdate{
			Revision:   view.Revision,
			CaptureDNS: &resolver,
		})
		return err

	case botExtensionPayloadReorder:
		if mutationErr != nil {
			return mutationErr
		}
		view, _, err := requireBotExtensionModule(bt, payload)
		if err != nil {
			return err
		}
		if mutation.ExecutionOrder == nil {
			return errors.New("confirmed execution order is missing")
		}
		_, err = bt.ctrl.ReorderInterceptModules(ctx, view.Revision, mutation.ExecutionOrder)
		return err

	case botExtensionPayloadMITM:
		if mutationErr != nil {
			return mutationErr
		}
		if mutation.MITM == nil {
			return errors.New("confirmed MITM settings are missing")
		}
		settings, err := bt.ctrl.InterceptSettings()
		if err != nil {
			return err
		}
		if settings.Revision != payload.Revision || botExtensionMITMDigest(settings) != payload.Digest {
			return errInterceptRevisionConflict
		}
		_, err = bt.ctrl.UpdateInterceptSettings(ctx, settings.Revision, *mutation.MITM)
		return err
	default:
		return errors.New("unsupported extension confirmation operation")
	}
}

func requireBotExtensionSource(
	bt *Bot,
	revision, sourceID, snapshotDigest string,
) (marketplaceView, marketplaceSourceView, error) {
	view, err := bt.ctrl.ExtensionMarketplaces()
	if err != nil {
		return marketplaceView{}, marketplaceSourceView{}, err
	}
	if view.Revision != revision {
		return view, marketplaceSourceView{}, errMarketplaceRevision
	}
	for _, source := range view.Sources {
		if source.ID == sourceID && source.SnapshotDigest == snapshotDigest {
			return view, source, nil
		}
	}
	return view, marketplaceSourceView{}, errors.New("marketplace source snapshot changed since review")
}

func (bt *Bot) applyBotExtensionInstall(
	ctx context.Context,
	payload botExtensionStatePayload,
	mutation botExtensionMutation,
) error {
	if !validSHA256(payload.CandidateDigest) {
		return errors.New("confirmed install candidate digest is invalid")
	}
	switch mutation.Mode {
	case "marketplace":
		market, source, err := requireBotExtensionSource(bt, payload.Revision, payload.SourceID, payload.Digest)
		if err != nil {
			return err
		}
		foundEntry := false
		for _, entry := range source.Entries {
			if entry.ID == payload.EntryID && entry.ManifestDigest == mutation.ManifestDigest {
				foundEntry = true
				break
			}
		}
		if !foundEntry || mutation.SourceDigest != source.SnapshotDigest {
			return errors.New("marketplace entry changed since review")
		}
		modules, err := bt.ctrl.InterceptModules()
		if err != nil {
			return err
		}
		if modules.Revision != payload.ModuleRevision {
			return errInterceptRevisionConflict
		}
		_, err = bt.ctrl.InstallMarketplaceExtensionExpected(
			ctx,
			source.ID,
			payload.EntryID,
			market.Revision,
			modules.Revision,
			payload.Digest,
			payload.CandidateDigest,
		)
		return err

	case "url", "local":
		modules, err := bt.ctrl.InterceptModules()
		if err != nil {
			return err
		}
		if modules.Revision != payload.Revision {
			return errInterceptRevisionConflict
		}
		request := interceptModuleImportRequest{Revision: modules.Revision}
		if mutation.Mode == "url" {
			request.URL = mutation.URL
		} else {
			request.Content = mutation.Content
		}
		_, err = bt.ctrl.ImportInterceptModuleExpected(ctx, request, payload.CandidateDigest)
		return err
	default:
		return errors.New("unsupported confirmed install mode")
	}
}

func botExtensionConfirmationDebugHTML(payload botExtensionStatePayload) string {
	return "<code>" + html.EscapeString(string(payload.Kind)) + "</code>"
}
