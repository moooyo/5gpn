package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"strconv"
	"strings"
	"time"

	"github.com/go-telegram/bot"
	"github.com/go-telegram/bot/models"
)

const (
	botExtensionPageSize       = 5
	maxBotExtensionReviewBytes = 32 << 20

	botExtensionPayloadMITM botExtensionPayloadKind = "mitm-settings"
)

type botExtensionMutation struct {
	Mode            string                     `json:"mode,omitempty"`
	URL             string                     `json:"url,omitempty"`
	Name            string                     `json:"name,omitempty"`
	Content         string                     `json:"content,omitempty"`
	SourceDigest    string                     `json:"source_digest,omitempty"`
	ManifestDigest  string                     `json:"manifest_digest,omitempty"`
	CurrentDigest   string                     `json:"current_digest,omitempty"`
	CandidateDigest string                     `json:"candidate_digest,omitempty"`
	Settings        map[string]json.RawMessage `json:"settings,omitempty"`
	ExecutionOrder  []string                   `json:"execution_order,omitempty"`
	MITM            *interceptMITMSettings     `json:"mitm,omitempty"`
}

func handleBotExtensionPage(raw string) (int, bool) {
	page, err := strconv.Atoi(raw)
	return page, err == nil && page >= 0 && page <= 10000
}

func botExtensionCallbackData(action string) string {
	return versionedCallback("ext:" + action)
}

func botExtensionButton(label, action string) models.InlineKeyboardButton {
	return models.InlineKeyboardButton{Text: label, CallbackData: botExtensionCallbackData(action)}
}

func botExtensionBack(action string) *models.InlineKeyboardMarkup {
	return &models.InlineKeyboardMarkup{InlineKeyboard: [][]models.InlineKeyboardButton{{
		botExtensionButton("« 返回", action),
	}}}
}

func botExtensionConfirmationMenu(kind botExtensionPayloadKind, token string) *models.InlineKeyboardMarkup {
	if !validBotExtensionToken(token) || !knownBotExtensionConfirmationKind(kind) {
		return botExtensionBack("modules")
	}
	return &models.InlineKeyboardMarkup{InlineKeyboard: [][]models.InlineKeyboardButton{{
		botExtensionButton("✅ 确认执行", "confirm:"+string(kind)+":"+token),
		botExtensionButton("取消", "cancel:"+token),
	}}}
}

func botExtensionExpiry(expires time.Time) string {
	return "\n\n确认仅可使用一次，并将于 <code>" + html.EscapeString(expires.Format("15:04:05")) + "</code> 过期。"
}

func marshalBotExtensionMutation(value botExtensionMutation) (json.RawMessage, error) {
	body, err := json.Marshal(value)
	if err != nil {
		return nil, fmt.Errorf("encode bot extension mutation: %w", err)
	}
	return body, nil
}

func decodeBotExtensionMutation(raw json.RawMessage) (botExtensionMutation, error) {
	var mutation botExtensionMutation
	if len(raw) == 0 {
		return mutation, errors.New("missing extension mutation payload")
	}
	if err := unmarshalStrictJSON(raw, &mutation); err != nil {
		return mutation, fmt.Errorf("decode extension mutation payload: %w", err)
	}
	return mutation, nil
}

func (bt *Bot) issueBotExtensionConfirmation(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	adminID, chatID int64,
	payload botExtensionStatePayload,
	prompt string,
) {
	bt.extensionReviewMu.Lock()
	defer bt.extensionReviewMu.Unlock()
	if !bt.botExtensionOperationCurrent(ctx) {
		return
	}
	bt.edit(ctx, b, cq, "⏳ 正在发送完整操作审查…", nil)
	if err := bt.sendBotExtensionReview(ctx, b, chatID, prompt); err != nil {
		if !bt.botExtensionOperationCurrent(ctx) {
			return
		}
		bt.send(ctx, b, chatID, "❌ 审查内容未能完整送达，未创建确认请求："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	token, expires, err := bt.extensionStateStore().IssueConfirmationForOperation(ctx, payload)
	if err != nil {
		if !bt.botExtensionOperationCurrent(ctx) {
			return
		}
		bt.send(ctx, b, chatID, "❌ 无法创建确认请求："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	if !bt.botExtensionOperationCurrent(ctx) {
		bt.extensionStateStore().CancelConfirmation(token, adminID, chatID)
		return
	}
	if err := sendBotExtensionConfirmControl(ctx, b, chatID, payload, token, expires); err != nil {
		bt.extensionStateStore().CancelConfirmation(token, adminID, chatID)
		bt.send(ctx, b, chatID, "❌ 确认控件发送失败，确认请求已撤销："+pre(err.Error()), botExtensionBack("modules"))
	}
}

func (bt *Bot) sendBotExtensionConfirmation(
	ctx context.Context,
	b *bot.Bot,
	adminID, chatID int64,
	payload botExtensionStatePayload,
	prompt string,
	back string,
) {
	bt.extensionReviewMu.Lock()
	defer bt.extensionReviewMu.Unlock()
	if !bt.botExtensionOperationCurrent(ctx) {
		return
	}
	if err := bt.sendBotExtensionReview(ctx, b, chatID, prompt); err != nil {
		if !bt.botExtensionOperationCurrent(ctx) {
			return
		}
		bt.send(ctx, b, chatID, "❌ 审查内容未能完整送达，未创建确认请求："+pre(err.Error()), botExtensionBack(back))
		return
	}
	token, expires, err := bt.extensionStateStore().IssueConfirmationForOperation(ctx, payload)
	if err != nil {
		if !bt.botExtensionOperationCurrent(ctx) {
			return
		}
		bt.send(ctx, b, chatID, "❌ 无法创建确认请求："+pre(err.Error()), botExtensionBack(back))
		return
	}
	if !bt.botExtensionOperationCurrent(ctx) {
		bt.extensionStateStore().CancelConfirmation(token, adminID, chatID)
		return
	}
	if err := sendBotExtensionConfirmControl(ctx, b, chatID, payload, token, expires); err != nil {
		bt.extensionStateStore().CancelConfirmation(token, adminID, chatID)
		bt.send(ctx, b, chatID, "❌ 确认控件发送失败，确认请求已撤销："+pre(err.Error()), botExtensionBack(back))
	}
}

func (bt *Bot) sendBotExtensionReview(ctx context.Context, b *bot.Bot, chatID int64, review string) error {
	if len(review) == 0 || len(review) > maxBotExtensionReviewBytes {
		return fmt.Errorf("extension review must contain 1 to %d bytes", maxBotExtensionReviewBytes)
	}
	if len(review) > 4*3900 {
		if !bt.botExtensionOperationCurrent(ctx) {
			return errors.New("extension operation was cancelled")
		}
		document := "<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\"><title>5gpn extension review</title><style>body{white-space:pre-wrap;overflow-wrap:anywhere}</style></head><body>" + review + "</body></html>"
		_, err := b.SendDocument(ctx, &bot.SendDocumentParams{
			ChatID: chatID,
			Document: &models.InputFileUpload{
				Filename: "5gpn-extension-review.html",
				Data:     bytes.NewReader([]byte(document)),
			},
			Caption:                     "📄 <b>完整插件操作审查</b>\n内容较长，已作为受保护的 HTML 文档发送；确认控件只会在文档完整送达后出现。",
			ParseMode:                   models.ParseModeHTML,
			ProtectContent:              true,
			DisableContentTypeDetection: true,
		})
		if err != nil {
			return fmt.Errorf("send protected review document: %w", err)
		}
		return nil
	}
	chunks := chunkText(review, 3900)
	for index, chunk := range chunks {
		if !bt.botExtensionOperationCurrent(ctx) {
			return errors.New("extension operation was cancelled")
		}
		if _, err := b.SendMessage(ctx, &bot.SendMessageParams{
			ChatID:             chatID,
			Text:               chunk,
			ParseMode:          models.ParseModeHTML,
			LinkPreviewOptions: disabledPreview(),
			ProtectContent:     true,
		}); err != nil {
			return fmt.Errorf("send review part %d: %w", index+1, err)
		}
	}
	return nil
}

func sendBotExtensionDetailDocument(
	ctx context.Context,
	b *bot.Bot,
	chatID int64,
	filename, caption, content string,
) error {
	if len(content) == 0 || len(content) > maxBotExtensionReviewBytes {
		return fmt.Errorf("extension detail must contain 1 to %d bytes", maxBotExtensionReviewBytes)
	}
	document := "<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\"><title>5gpn extension detail</title><style>body{white-space:pre-wrap;overflow-wrap:anywhere}</style></head><body>" + content + "</body></html>"
	_, err := b.SendDocument(ctx, &bot.SendDocumentParams{
		ChatID: chatID,
		Document: &models.InputFileUpload{
			Filename: filename,
			Data:     bytes.NewReader([]byte(document)),
		},
		Caption:                     caption,
		ParseMode:                   models.ParseModeHTML,
		ProtectContent:              true,
		DisableContentTypeDetection: true,
	})
	return err
}

func sendBotExtensionConfirmControl(
	ctx context.Context,
	b *bot.Bot,
	chatID int64,
	payload botExtensionStatePayload,
	token string,
	expires time.Time,
) error {
	_, err := b.SendMessage(ctx, &bot.SendMessageParams{
		ChatID:             chatID,
		Text:               botExtensionConfirmControlHTML(payload) + botExtensionExpiry(expires),
		ParseMode:          models.ParseModeHTML,
		LinkPreviewOptions: disabledPreview(),
		ProtectContent:     true,
		ReplyMarkup:        botExtensionConfirmationMenu(payload.Kind, token),
	})
	return err
}

func botExtensionConfirmControlHTML(payload botExtensionStatePayload) string {
	var text strings.Builder
	text.WriteString("以上审查内容已完整送达。\n操作：<code>")
	text.WriteString(html.EscapeString(string(payload.Kind)))
	text.WriteString("</code>")
	for _, item := range []struct {
		label string
		value string
	}{{"插件", payload.ModuleID}, {"来源", payload.SourceID}, {"条目", payload.EntryID}} {
		if item.value != "" {
			text.WriteString("\n")
			text.WriteString(item.label)
			text.WriteString("：<code>")
			text.WriteString(html.EscapeString(item.value))
			text.WriteString("</code>")
		}
	}
	if payload.Digest != "" {
		text.WriteString("\n摘要：<code>")
		text.WriteString(html.EscapeString(truncateRunes(payload.Digest, 12)))
		text.WriteString("</code>")
	}
	if payload.CandidateDigest != "" && payload.CandidateDigest != payload.Digest {
		text.WriteString("\n候选：<code>")
		text.WriteString(html.EscapeString(truncateRunes(payload.CandidateDigest, 12)))
		text.WriteString("</code>")
	}
	text.WriteString("\n请确认是否执行。")
	return text.String()
}

func knownBotExtensionConfirmationKind(kind botExtensionPayloadKind) bool {
	switch kind {
	case botExtensionPayloadMarketplaceAdd,
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
		botExtensionPayloadMITM:
		return true
	default:
		return false
	}
}

func (bt *Bot) handleExtensionCallback(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	arg string,
) {
	if !strings.HasPrefix(arg, "confirm:") && !strings.HasPrefix(arg, "cancel:") {
		owner, generation, err := bt.extensionStateStore().BeginOperation(uid, chatID)
		if err != nil {
			bt.edit(ctx, b, cq, "❌ 无法开始插件操作："+pre(err.Error()), botExtensionBack("modules"))
			return
		}
		ctx = withBotExtensionOperation(ctx, owner, generation)
		var finish func()
		ctx, finish = bt.startBotExtensionOperation(ctx, owner, generation)
		defer finish()
		releaseRender, err := bt.acquireBotExtensionRender(ctx)
		if err != nil {
			return
		}
		defer releaseRender()
	}
	switch arg {
	case "modules":
		bt.renderBotExtensionModules(ctx, b, cq, uid, 0, "")
		return
	case "market":
		bt.renderBotExtensionMarket(ctx, b, cq, uid, 0, "")
		return
	case "install:url":
		bt.beginBotExtensionImport(ctx, b, cq, uid, chatID, botExtensionInputModuleURL)
		return
	case "install:local":
		bt.beginBotExtensionImport(ctx, b, cq, uid, chatID, botExtensionInputLocalYAML)
		return
	case "market:add:official":
		bt.previewBotExtensionMarketplaceAdd(ctx, b, cq, uid, chatID, true)
		return
	case "market:add:custom":
		bt.beginBotExtensionMarketplaceAdd(ctx, b, cq, uid, chatID)
		return
	case "mitm":
		bt.renderBotExtensionMITM(ctx, b, cq, uid, "")
		return
	}

	if prefix, rest, ok := cutBotExtensionAction(arg); ok {
		switch prefix {
		case "modules":
			if page, valid := handleBotExtensionPage(rest); valid {
				bt.renderBotExtensionModules(ctx, b, cq, uid, page, "")
				return
			}
		case "market":
			if page, valid := handleBotExtensionPage(rest); valid {
				bt.renderBotExtensionMarket(ctx, b, cq, uid, page, "")
				return
			}
		case "source":
			bt.handleBotExtensionSourceCallback(ctx, b, cq, uid, chatID, rest)
			return
		case "entry":
			bt.handleBotExtensionEntryCallback(ctx, b, cq, uid, chatID, rest)
			return
		case "module":
			bt.handleBotExtensionModuleCallback(ctx, b, cq, uid, chatID, rest)
			return
		case "settings":
			bt.handleBotExtensionSettingsCallback(ctx, b, cq, uid, chatID, rest)
			return
		case "setting":
			bt.handleBotExtensionSettingCallback(ctx, b, cq, uid, chatID, rest)
			return
		case "egress":
			bt.handleBotExtensionEgressCallback(ctx, b, cq, uid, chatID, rest)
			return
		case "capture-dns":
			bt.handleBotExtensionCaptureDNSCallback(ctx, b, cq, uid, chatID, rest)
			return
		case "mitm":
			bt.handleBotExtensionMITMCallback(ctx, b, cq, uid, chatID, rest)
			return
		case "confirm":
			bt.executeBotExtensionConfirmation(ctx, b, cq, uid, chatID, rest)
			return
		case "cancel":
			if bt.extensionStateStore().CancelConfirmation(rest, uid, chatID) {
				bt.edit(ctx, b, cq, "已取消，未执行任何插件变更。", botExtensionBack("modules"))
			} else {
				bt.edit(ctx, b, cq, "确认请求已失效或不属于当前管理员。", botExtensionBack("modules"))
			}
			return
		}
	}
	bt.edit(ctx, b, cq, "未知或已失效的插件操作。", botExtensionBack("modules"))
}

func cutBotExtensionAction(arg string) (string, string, bool) {
	prefix, rest, ok := strings.Cut(arg, ":")
	return prefix, rest, ok && prefix != "" && rest != ""
}

func pageBounds(total, page, size int) (int, int, int) {
	if size <= 0 {
		size = 1
	}
	pages := (total + size - 1) / size
	if pages == 0 {
		pages = 1
	}
	if page < 0 {
		page = 0
	}
	if page >= pages {
		page = pages - 1
	}
	start := page * size
	end := start + size
	if end > total {
		end = total
	}
	return start, end, pages
}

func botExtensionPageRow(prefix string, page, pages int) []models.InlineKeyboardButton {
	row := make([]models.InlineKeyboardButton, 0, 3)
	if page > 0 {
		row = append(row, botExtensionButton("‹ 上一页", prefix+":"+strconv.Itoa(page-1)))
	}
	row = append(row, models.InlineKeyboardButton{Text: fmt.Sprintf("%d/%d", page+1, pages), CallbackData: botExtensionCallbackData(prefix + ":" + strconv.Itoa(page))})
	if page+1 < pages {
		row = append(row, botExtensionButton("下一页 ›", prefix+":"+strconv.Itoa(page+1)))
	}
	return row
}

func truncateBotExtensionLabel(value string, max int) string {
	runes := []rune(strings.TrimSpace(value))
	if len(runes) <= max {
		return string(runes)
	}
	return string(runes[:max-1]) + "…"
}

func (bt *Bot) renderBotExtensionMarket(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid int64,
	page int,
	notice string,
) {
	view, err := bt.ctrl.ExtensionMarketplaces()
	if err != nil {
		bt.edit(ctx, b, cq, "❌ 插件市场不可用："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	if _, err := bt.extensionStateStore().CancelSelectionsByKindForOperation(ctx, botExtensionPayloadMarketplaceSource); err != nil {
		return
	}
	if _, err := bt.extensionStateStore().CancelSelectionsByKindForOperation(ctx, botExtensionPayloadMarketplaceEntry); err != nil {
		return
	}
	start, end, pages := pageBounds(len(view.Sources), page, botExtensionPageSize)
	page = start / botExtensionPageSize
	var text strings.Builder
	text.WriteString("<b>插件市场</b>\n市场元数据仅用于发现；安装时会重新获取并验证完整插件快照。")
	if notice != "" {
		text.WriteString("\n\n")
		text.WriteString(notice)
	}
	if len(view.Sources) == 0 {
		text.WriteString("\n\n尚未添加任何市场来源。")
	} else {
		text.WriteString(fmt.Sprintf("\n\n来源：<code>%d</code> · 第 <code>%d/%d</code> 页", len(view.Sources), page+1, pages))
	}

	rows := make([][]models.InlineKeyboardButton, 0, botExtensionPageSize+5)
	for index := start; index < end; index++ {
		source := view.Sources[index]
		token, _, issueErr := bt.extensionStateStore().IssueSelectionForOperation(ctx, botExtensionStatePayload{
			Kind:     botExtensionPayloadMarketplaceSource,
			Revision: view.Revision,
			SourceID: source.ID,
			Digest:   source.SnapshotDigest,
		})
		if issueErr != nil {
			bt.edit(ctx, b, cq, "❌ 无法创建市场选择："+pre(issueErr.Error()), botExtensionBack("modules"))
			return
		}
		label := fmt.Sprintf("%s · %d 个插件", truncateBotExtensionLabel(source.Name, 28), len(source.Entries))
		rows = append(rows, []models.InlineKeyboardButton{botExtensionButton(label, "source:"+token)})
	}
	if pages > 1 {
		rows = append(rows, botExtensionPageRow("market", page, pages))
	}
	rows = append(rows,
		[]models.InlineKeyboardButton{botExtensionButton("⭐ 添加官方来源", "market:add:official")},
		[]models.InlineKeyboardButton{botExtensionButton("➕ 添加自定义 HTTPS 来源", "market:add:custom")},
		[]models.InlineKeyboardButton{botExtensionButton("🔄 刷新列表", "market")},
		[]models.InlineKeyboardButton{botExtensionButton("« 返回", "modules")},
	)
	bt.edit(ctx, b, cq, text.String(), &models.InlineKeyboardMarkup{InlineKeyboard: rows})
}

func callbackChatID(cq *models.CallbackQuery) int64 {
	chatID, _, _ := callbackTarget(cq)
	return chatID
}

func (bt *Bot) beginBotExtensionMarketplaceAdd(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
) {
	view, err := bt.ctrl.ExtensionMarketplaces()
	if err != nil {
		bt.edit(ctx, b, cq, "❌ 插件市场不可用："+pre(err.Error()), botExtensionBack("market"))
		return
	}
	_, err = bt.extensionStateStore().BeginInputForOperation(ctx, botExtensionInputMarketplaceURL, botExtensionStatePayload{
		Kind:     botExtensionPayloadMarketplaceAdd,
		Revision: view.Revision,
	})
	if err != nil {
		bt.edit(ctx, b, cq, "❌ 无法开始输入："+pre(err.Error()), botExtensionBack("market"))
		return
	}
	bt.edit(ctx, b, cq,
		"请发送一个明确的 <code>https://</code> 市场索引 URL。\n随后机器人会询问本地显示名称；发送 /cancel 可取消。",
		botExtensionBack("market"))
}

func (bt *Bot) previewBotExtensionMarketplaceAdd(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	official bool,
) {
	view, err := bt.ctrl.ExtensionMarketplaces()
	if err != nil {
		bt.edit(ctx, b, cq, "❌ 插件市场不可用："+pre(err.Error()), botExtensionBack("market"))
		return
	}
	if !official || strings.TrimSpace(view.RecommendedURL) == "" {
		bt.beginBotExtensionMarketplaceAdd(ctx, b, cq, uid, chatID)
		return
	}
	bt.previewBotExtensionMarketplaceAddValues(ctx, b, cq, uid, chatID, view.Revision, view.RecommendedURL, "")
}

func (bt *Bot) previewBotExtensionMarketplaceAddValues(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	revision, rawURL, name string,
) {
	current, err := bt.ctrl.ExtensionMarketplaces()
	if err != nil || current.Revision != revision {
		if err == nil {
			err = errMarketplaceRevision
		}
		bt.edit(ctx, b, cq, "⚠️ 市场状态已变化，请重新开始："+pre(err.Error()), botExtensionBack("market"))
		return
	}
	bt.edit(ctx, b, cq, "⏳ 正在安全获取并验证市场索引…", nil)
	release, err := bt.acquireBotExtensionFetch(ctx)
	if err != nil {
		return
	}
	candidate, err := bt.ctrl.PreviewExtensionMarketplaceAdd(ctx, rawURL, name)
	release()
	if err != nil {
		bt.edit(ctx, b, cq, "❌ 市场索引验证失败："+pre(err.Error()), botExtensionBack("market"))
		return
	}
	mutationRaw, err := marshalBotExtensionMutation(botExtensionMutation{URL: rawURL, Name: name})
	if err != nil {
		bt.edit(ctx, b, cq, "❌ 无法准备市场确认："+pre(err.Error()), botExtensionBack("market"))
		return
	}
	payload := botExtensionStatePayload{
		Kind:     botExtensionPayloadMarketplaceAdd,
		Revision: revision,
		SourceID: candidate.ID,
		Digest:   candidate.SnapshotDigest,
		RawJSON:  mutationRaw,
	}
	prompt := "⚠️ <b>确认添加插件市场来源？</b>\n" + marketplaceSourceReviewHTML(candidate) +
		"\n\n远端名称和描述来自索引；本地显示名称只是别名，两者都不代表发布者身份。添加只保存经过验证的完整索引快照，不会自动安装或启用插件。"
	bt.issueBotExtensionConfirmation(ctx, b, cq, uid, chatID, payload, prompt)
}

func marketplaceSourceReviewHTML(source marketplaceSourceView) string {
	displayName := "<i>未设置（界面跟随远端名称）</i>"
	if source.DisplayName != "" {
		displayName = "<b>" + html.EscapeString(source.DisplayName) + "</b>"
	}
	var text strings.Builder
	fmt.Fprintf(&text,
		"本地显示名称：%s\n远端 metadata.name：<b>%s</b>\n远端 metadata.id：<code>%s</code>\n远端描述：%s\n远端主页：<code>%s</code>\n索引 URL：<code>%s</code>\n最终 URL：<code>%s</code>\n条目数：<code>%d</code>\n远端索引摘要：<code>%s</code>\n规范化索引快照：<code>%s</code>",
		displayName,
		html.EscapeString(source.MetadataName),
		html.EscapeString(source.ID),
		html.EscapeString(source.Description),
		html.EscapeString(source.Homepage),
		html.EscapeString(source.URL),
		html.EscapeString(source.FinalURL),
		len(source.Entries),
		html.EscapeString(source.Digest),
		html.EscapeString(source.SnapshotDigest),
	)
	for index, entry := range source.Entries {
		fmt.Fprintf(&text,
			"\n\n<b>条目 %d/%d</b>\n名称：<b>%s</b>\nID：<code>%s</code>\n版本：<code>%s</code>\n描述：%s\n许可证：<code>%s</code>\nManifest URL：<code>%s</code>\nManifest 摘要：<code>%s</code>"+
				"\n能力：<code>%d</code> capture hosts · <code>%d</code> actions · <code>%d</code> settings · <code>%d</code> mappings · <code>%d</code> global routing rules · storage=<code>%t</code> · egress-required=<code>%t</code>",
			index+1, len(source.Entries),
			html.EscapeString(entry.Name), html.EscapeString(entry.ID), html.EscapeString(entry.Version),
			html.EscapeString(entry.Description), html.EscapeString(entry.License.SPDX),
			html.EscapeString(entry.ManifestURL), html.EscapeString(entry.ManifestDigest),
			entry.Capabilities.CaptureHostCount, entry.Capabilities.ActionCount,
			entry.Capabilities.SettingCount, entry.Capabilities.UpstreamMappingCount,
			entry.Capabilities.RoutingRuleCount,
			entry.Capabilities.PersistentStorage, entry.Capabilities.EgressGroupRequired,
		)
		text.WriteString("\n声明的 network origins（仅市场元数据；安装与启用仍需独立审查）：")
		if len(entry.Capabilities.NetworkOrigins) == 0 {
			text.WriteString("<i>无</i>")
			continue
		}
		for _, origin := range entry.Capabilities.NetworkOrigins {
			text.WriteString("\n• <code>")
			text.WriteString(html.EscapeString(origin))
			text.WriteString("</code>")
		}
	}
	return text.String()
}

func (bt *Bot) handleBotExtensionSourceCallback(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	rest string,
) {
	if token, ok := strings.CutPrefix(rest, "refresh:"); ok {
		bt.previewBotExtensionMarketplaceRefresh(ctx, b, cq, uid, chatID, token)
		return
	}
	if token, ok := strings.CutPrefix(rest, "delete:"); ok {
		bt.previewBotExtensionMarketplaceDelete(ctx, b, cq, uid, chatID, token)
		return
	}
	token := rest
	page := 0
	if head, tail, ok := strings.Cut(rest, ":"); ok {
		token = head
		var valid bool
		page, valid = handleBotExtensionPage(tail)
		if !valid {
			bt.edit(ctx, b, cq, "市场分页参数无效。", botExtensionBack("market"))
			return
		}
	}
	bt.renderBotExtensionMarketplaceSource(ctx, b, cq, uid, token, page, "")
}

func (bt *Bot) resolveBotExtensionSource(
	uid, chatID int64,
	token string,
) (marketplaceView, marketplaceSourceView, botExtensionStatePayload, error) {
	payload, ok := bt.extensionStateStore().ResolveSelection(token, uid, chatID, botExtensionPayloadMarketplaceSource)
	if !ok {
		return marketplaceView{}, marketplaceSourceView{}, payload, errors.New("市场选择已过期或不属于当前管理员")
	}
	view, err := bt.ctrl.ExtensionMarketplaces()
	if err != nil {
		return marketplaceView{}, marketplaceSourceView{}, payload, err
	}
	if view.Revision != payload.Revision {
		return view, marketplaceSourceView{}, payload, errMarketplaceRevision
	}
	for _, source := range view.Sources {
		if source.ID == payload.SourceID && source.SnapshotDigest == payload.Digest {
			return view, source, payload, nil
		}
	}
	return view, marketplaceSourceView{}, payload, errors.New("市场来源快照已变化或已删除")
}

func (bt *Bot) renderBotExtensionMarketplaceSource(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid int64,
	token string,
	page int,
	notice string,
) {
	view, source, _, err := bt.resolveBotExtensionSource(uid, callbackChatID(cq), token)
	if err != nil {
		bt.edit(ctx, b, cq, "⚠️ 无法打开市场来源："+pre(err.Error()), botExtensionBack("market"))
		return
	}
	if _, err := bt.extensionStateStore().CancelSelectionsByKindForOperation(ctx, botExtensionPayloadMarketplaceEntry); err != nil {
		return
	}
	start, end, pages := pageBounds(len(source.Entries), page, botExtensionPageSize)
	page = start / botExtensionPageSize
	var text strings.Builder
	text.WriteString("<b>")
	text.WriteString(html.EscapeString(source.Name))
	text.WriteString("</b>\n远端名称：<b>")
	text.WriteString(html.EscapeString(source.MetadataName))
	text.WriteString("</b>\n")
	text.WriteString(html.EscapeString(source.Description))
	text.WriteString(fmt.Sprintf("\n\n条目：<code>%d</code> · 第 <code>%d/%d</code> 页\n索引快照：<code>%s</code>",
		len(source.Entries), page+1, pages, html.EscapeString(source.SnapshotDigest)))
	if notice != "" {
		text.WriteString("\n\n")
		text.WriteString(notice)
	}
	rows := make([][]models.InlineKeyboardButton, 0, botExtensionPageSize+4)
	for index := start; index < end; index++ {
		entry := source.Entries[index]
		raw, _ := marshalBotExtensionMutation(botExtensionMutation{SourceDigest: source.SnapshotDigest, ManifestDigest: entry.ManifestDigest})
		entryToken, _, issueErr := bt.extensionStateStore().IssueSelectionForOperation(ctx, botExtensionStatePayload{
			Kind:     botExtensionPayloadMarketplaceEntry,
			Revision: view.Revision,
			SourceID: source.ID,
			EntryID:  entry.ID,
			Digest:   entry.ManifestDigest,
			RawJSON:  raw,
		})
		if issueErr != nil {
			bt.edit(ctx, b, cq, "❌ 无法创建插件选择："+pre(issueErr.Error()), botExtensionBack("market"))
			return
		}
		label := fmt.Sprintf("%s · %s", truncateBotExtensionLabel(entry.Name, 24), truncateBotExtensionLabel(entry.Version, 12))
		rows = append(rows, []models.InlineKeyboardButton{botExtensionButton(label, "entry:"+entryToken)})
	}
	if pages > 1 {
		rows = append(rows, botExtensionSourcePageRow(token, page, pages))
	}
	rows = append(rows,
		[]models.InlineKeyboardButton{
			botExtensionButton("🔄 刷新来源", "source:refresh:"+token),
			botExtensionButton("🗑 删除来源", "source:delete:"+token),
		},
		[]models.InlineKeyboardButton{botExtensionButton("« 返回", "market")},
	)
	bt.edit(ctx, b, cq, text.String(), &models.InlineKeyboardMarkup{InlineKeyboard: rows})
}

func botExtensionSourcePageRow(token string, page, pages int) []models.InlineKeyboardButton {
	row := make([]models.InlineKeyboardButton, 0, 3)
	if page > 0 {
		row = append(row, botExtensionButton("‹ 上一页", "source:"+token+":"+strconv.Itoa(page-1)))
	}
	row = append(row, botExtensionButton(fmt.Sprintf("%d/%d", page+1, pages), "source:"+token+":"+strconv.Itoa(page)))
	if page+1 < pages {
		row = append(row, botExtensionButton("下一页 ›", "source:"+token+":"+strconv.Itoa(page+1)))
	}
	return row
}

func (bt *Bot) previewBotExtensionMarketplaceRefresh(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	token string,
) {
	view, source, _, err := bt.resolveBotExtensionSource(uid, chatID, token)
	if err != nil {
		bt.edit(ctx, b, cq, "⚠️ 无法刷新来源："+pre(err.Error()), botExtensionBack("market"))
		return
	}
	bt.edit(ctx, b, cq, "⏳ 正在安全获取并验证新的完整索引…", nil)
	release, err := bt.acquireBotExtensionFetch(ctx)
	if err != nil {
		return
	}
	candidate, err := bt.ctrl.PreviewExtensionMarketplaceRefresh(ctx, source.ID, view.Revision)
	release()
	if err != nil {
		bt.edit(ctx, b, cq, "❌ 刷新预览失败，旧快照保持不变："+pre(err.Error()), botExtensionBack("market"))
		return
	}
	raw, _ := marshalBotExtensionMutation(botExtensionMutation{CurrentDigest: source.SnapshotDigest})
	payload := botExtensionStatePayload{
		Kind:     botExtensionPayloadMarketplaceRefresh,
		Revision: view.Revision,
		SourceID: source.ID,
		Digest:   candidate.SnapshotDigest,
		RawJSON:  raw,
	}
	prompt := "⚠️ <b>确认替换市场索引快照？</b>\n\n<b>当前规范化来源</b>\n" + marketplaceSourceReviewHTML(source) +
		"\n\n<b>候选规范化来源</b>\n" + marketplaceSourceReviewHTML(candidate) +
		"\n\n确认时会重新获取并要求候选快照完全一致；冲突不会静默重试。"
	bt.issueBotExtensionConfirmation(ctx, b, cq, uid, chatID, payload, prompt)
}

func (bt *Bot) previewBotExtensionMarketplaceDelete(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	token string,
) {
	view, source, _, err := bt.resolveBotExtensionSource(uid, chatID, token)
	if err != nil {
		bt.edit(ctx, b, cq, "⚠️ 无法删除来源："+pre(err.Error()), botExtensionBack("market"))
		return
	}
	payload := botExtensionStatePayload{
		Kind:     botExtensionPayloadMarketplaceDelete,
		Revision: view.Revision,
		SourceID: source.ID,
		Digest:   source.SnapshotDigest,
	}
	prompt := "⚠️ <b>确认删除市场来源？</b>\n" + marketplaceSourceReviewHTML(source) +
		"\n\n这只删除本地市场索引快照；已经安装的插件快照不会被卸载或更改。"
	bt.issueBotExtensionConfirmation(ctx, b, cq, uid, chatID, payload, prompt)
}

func (bt *Bot) handleBotExtensionEntryCallback(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	rest string,
) {
	if token, ok := strings.CutPrefix(rest, "install:"); ok {
		bt.previewBotExtensionMarketplaceInstall(ctx, b, cq, uid, chatID, token)
		return
	}
	view, source, entry, _, err := bt.resolveBotExtensionEntry(uid, chatID, rest)
	if err != nil {
		bt.edit(ctx, b, cq, "⚠️ 无法打开市场条目："+pre(err.Error()), botExtensionBack("market"))
		return
	}
	_ = view
	var text strings.Builder
	text.WriteString("<b>")
	text.WriteString(html.EscapeString(entry.Name))
	text.WriteString("</b> · <code>")
	text.WriteString(html.EscapeString(entry.Version))
	text.WriteString("</code>\n")
	text.WriteString(html.EscapeString(entry.Description))
	text.WriteString(fmt.Sprintf("\n\n来源：<b>%s</b>\nID：<code>%s</code>\n许可证：<code>%s</code>\nManifest：<code>%s</code>",
		html.EscapeString(source.Name), html.EscapeString(entry.ID), html.EscapeString(entry.License.SPDX), html.EscapeString(entry.ManifestDigest)))
	text.WriteString(fmt.Sprintf("\n\n能力：<code>%d</code> hosts · <code>%d</code> actions · <code>%d</code> settings · <code>%d</code> mappings · <code>%d</code> global routing rules",
		entry.Capabilities.CaptureHostCount, entry.Capabilities.ActionCount, entry.Capabilities.SettingCount, entry.Capabilities.UpstreamMappingCount, entry.Capabilities.RoutingRuleCount))
	if len(entry.Capabilities.NetworkOrigins) > 0 {
		text.WriteString("\n\n")
		text.WriteString(botExtensionNetworkRiskHTML(entry.Capabilities.NetworkOrigins))
	}
	rows := [][]models.InlineKeyboardButton{
		{botExtensionButton("📥 审查并安装", "entry:install:"+rest)},
		{botExtensionButton("« 返回", "market")},
	}
	bt.edit(ctx, b, cq, text.String(), &models.InlineKeyboardMarkup{InlineKeyboard: rows})
}

func (bt *Bot) resolveBotExtensionEntry(
	uid, chatID int64,
	token string,
) (marketplaceView, marketplaceSourceView, marketplaceEntryView, botExtensionStatePayload, error) {
	payload, ok := bt.extensionStateStore().ResolveSelection(token, uid, chatID, botExtensionPayloadMarketplaceEntry)
	if !ok {
		return marketplaceView{}, marketplaceSourceView{}, marketplaceEntryView{}, payload, errors.New("市场条目选择已过期或不属于当前管理员")
	}
	mutation, err := decodeBotExtensionMutation(payload.RawJSON)
	if err != nil {
		return marketplaceView{}, marketplaceSourceView{}, marketplaceEntryView{}, payload, err
	}
	view, err := bt.ctrl.ExtensionMarketplaces()
	if err != nil {
		return marketplaceView{}, marketplaceSourceView{}, marketplaceEntryView{}, payload, err
	}
	if view.Revision != payload.Revision {
		return view, marketplaceSourceView{}, marketplaceEntryView{}, payload, errMarketplaceRevision
	}
	for _, source := range view.Sources {
		if source.ID != payload.SourceID || source.SnapshotDigest != mutation.SourceDigest {
			continue
		}
		for _, entry := range source.Entries {
			if entry.ID == payload.EntryID && entry.ManifestDigest == payload.Digest && entry.ManifestDigest == mutation.ManifestDigest {
				return view, source, entry, payload, nil
			}
		}
	}
	return view, marketplaceSourceView{}, marketplaceEntryView{}, payload, errors.New("市场条目或来源快照已变化")
}

func (bt *Bot) previewBotExtensionMarketplaceInstall(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	token string,
) {
	market, source, entry, _, err := bt.resolveBotExtensionEntry(uid, chatID, token)
	if err != nil {
		bt.edit(ctx, b, cq, "⚠️ 无法安装市场条目："+pre(err.Error()), botExtensionBack("market"))
		return
	}
	modules, err := bt.ctrl.InterceptModules()
	if err != nil {
		bt.edit(ctx, b, cq, "❌ 插件状态不可用："+pre(err.Error()), botExtensionBack("market"))
		return
	}
	bt.edit(ctx, b, cq, "⏳ 正在重新获取并验证完整插件候选快照…", nil)
	release, err := bt.acquireBotExtensionFetch(ctx)
	if err != nil {
		return
	}
	candidate, err := bt.ctrl.PreviewMarketplaceExtensionInstall(ctx, source.ID, entry.ID, market.Revision, modules.Revision)
	release()
	if err != nil {
		bt.edit(ctx, b, cq, "❌ 安装候选验证失败："+pre(err.Error()), botExtensionBack("market"))
		return
	}
	raw, _ := marshalBotExtensionMutation(botExtensionMutation{
		Mode:           "marketplace",
		SourceDigest:   source.SnapshotDigest,
		ManifestDigest: entry.ManifestDigest,
	})
	payload := botExtensionStatePayload{
		Kind:            botExtensionPayloadInstall,
		Revision:        market.Revision,
		ModuleRevision:  modules.Revision,
		ModuleID:        candidate.ID,
		SourceID:        source.ID,
		EntryID:         entry.ID,
		Digest:          source.SnapshotDigest,
		CandidateDigest: candidate.SnapshotDigest,
		RawJSON:         raw,
	}
	prompt := "⚠️ <b>确认安装市场插件？</b>\n来源索引快照：<code>" + html.EscapeString(source.SnapshotDigest) + "</code>\n" +
		botExtensionCandidateReviewHTML(candidate) +
		"\n\n确认时会重新获取并同时验证来源索引与插件候选摘要。安装后插件保持关闭，不会发布流量接管。"
	bt.issueBotExtensionConfirmation(ctx, b, cq, uid, chatID, payload, prompt)
}

func botExtensionNetworkRiskHTML(origins []string) string {
	if len(origins) == 0 {
		return ""
	}
	var text strings.Builder
	text.WriteString("🌐 <b>联网权限风险</b>\n该脚本可以把它可见的全部解密请求、响应、参数和存储数据发送到以下每一个 origin，也可以把捕获的请求改写到这些 origin。改写会转发完整请求方法、解码后的请求体和端到端请求头，其中可能包含 Cookie 和 Authorization 凭据：")
	for _, origin := range origins {
		text.WriteString("\n• <code>")
		text.WriteString(html.EscapeString(origin))
		text.WriteString("</code>")
	}
	return text.String()
}

func botExtensionActionsHTML(actions []interceptModuleActionView) string {
	if len(actions) == 0 {
		return "<i>无</i>"
	}
	var text strings.Builder
	for index, action := range actions {
		text.WriteString("\n<b>")
		text.WriteString(strconv.Itoa(index + 1))
		text.WriteString(". ")
		text.WriteString(html.EscapeString(action.ID))
		text.WriteString("</b> · phase=<code>")
		text.WriteString(html.EscapeString(action.Phase))
		text.WriteString("</code> · body=<code>")
		text.WriteString(html.EscapeString(action.BodyMode))
		text.WriteString("</code>\n  hosts=<code>")
		text.WriteString(html.EscapeString(strings.Join(action.Match.Hosts, ", ")))
		text.WriteString("</code>\n  schemes=<code>")
		text.WriteString(html.EscapeString(strings.Join(action.Match.Schemes, ", ")))
		text.WriteString("</code> · methods=<code>")
		methods := strings.Join(action.Match.Methods, ", ")
		if methods == "" {
			methods = "全部方法"
		}
		text.WriteString(html.EscapeString(methods))
		text.WriteString("</code>\n  path=<code>")
		text.WriteString(html.EscapeString(action.Match.PathRegex))
		text.WriteString("</code>")
		if len(action.Match.StatusCodes) > 0 {
			statuses := make([]string, 0, len(action.Match.StatusCodes))
			for _, status := range action.Match.StatusCodes {
				statuses = append(statuses, strconv.Itoa(status))
			}
			text.WriteString(" · statuses=<code>")
			text.WriteString(html.EscapeString(strings.Join(statuses, ", ")))
			text.WriteString("</code>")
		}
		if action.ScriptURL != "" {
			text.WriteString("\n  script=<code>")
			text.WriteString(html.EscapeString(action.ScriptURL))
			text.WriteString("</code>")
		}
		text.WriteString("\n  script digest=<code>")
		text.WriteString(html.EscapeString(action.ScriptDigest))
		text.WriteString("</code> · timeout=<code>")
		text.WriteString(strconv.Itoa(action.TimeoutMS))
		text.WriteString("ms</code> · max body=<code>")
		text.WriteString(strconv.FormatInt(action.MaxBodyBytes, 10))
		text.WriteString("</code>")
	}
	return text.String()
}

func botExtensionSettingsSchemaHTML(settings []interceptModuleSetting) string {
	if len(settings) == 0 {
		return "<i>无</i>"
	}
	var text strings.Builder
	for index, setting := range settings {
		label := setting.Label
		if strings.TrimSpace(label) == "" {
			label = setting.Key
		}
		text.WriteString("\n")
		text.WriteString(strconv.Itoa(index + 1))
		text.WriteString(". <code>")
		text.WriteString(html.EscapeString(setting.Key))
		text.WriteString("</code> · ")
		text.WriteString(html.EscapeString(label))
		text.WriteString(" · <code>")
		text.WriteString(html.EscapeString(setting.Type))
		text.WriteString("</code>")
		if setting.Required {
			text.WriteString(" · 必填")
		}
		if setting.Description != "" {
			text.WriteString("\n   描述：")
			text.WriteString(html.EscapeString(setting.Description))
		}
		if len(setting.Options) > 0 {
			text.WriteString("\n   Options：")
			for optionIndex, option := range setting.Options {
				if optionIndex > 0 {
					text.WriteString(" | ")
				}
				text.WriteString("<code>")
				text.WriteString(html.EscapeString(option))
				text.WriteString("</code>")
			}
		}
		if setting.Min != nil || setting.Max != nil {
			text.WriteString("\n   范围：")
			if setting.Min == nil {
				text.WriteString("−∞")
			} else {
				text.WriteString("<code>" + strconv.FormatFloat(*setting.Min, 'g', -1, 64) + "</code>")
			}
			text.WriteString(" … ")
			if setting.Max == nil {
				text.WriteString("+∞")
			} else {
				text.WriteString("<code>" + strconv.FormatFloat(*setting.Max, 'g', -1, 64) + "</code>")
			}
		}
		text.WriteString("\n   Default：")
		text.WriteString(botExtensionSettingRawValueHTML(setting, setting.Default))
		text.WriteString(" · Current：")
		text.WriteString(botExtensionSettingValueHTML(setting))
	}
	return text.String()
}

func botExtensionCandidateReviewHTML(module interceptModuleView) string {
	var text strings.Builder
	text.WriteString("插件：<b>")
	text.WriteString(html.EscapeString(module.Name))
	text.WriteString("</b> · <code>")
	text.WriteString(html.EscapeString(module.Version))
	text.WriteString("</code>\nID：<code>")
	text.WriteString(html.EscapeString(module.ID))
	text.WriteString("</code>\n候选快照：<code>")
	text.WriteString(html.EscapeString(module.SnapshotDigest))
	text.WriteString("</code>")
	if module.SourceURL != "" {
		text.WriteString("\nSource URL：<code>")
		text.WriteString(html.EscapeString(module.SourceURL))
		text.WriteString("</code>")
	}
	if module.SourceDigest != "" {
		text.WriteString("\nManifest digest：<code>")
		text.WriteString(html.EscapeString(module.SourceDigest))
		text.WriteString("</code>")
	}
	text.WriteString("\n提交后状态：<b>关闭</b>")
	if module.ExecutionOrder > 0 {
		text.WriteString("\n执行位置：<code>")
		text.WriteString(strconv.Itoa(module.ExecutionOrder))
		text.WriteString("</code>")
	}
	if module.EgressGroupRequired {
		text.WriteString("\n出口要求：<b>必须由管理员绑定</b>")
	}
	if module.EgressGroup != "" {
		text.WriteString("\n保留出口绑定：<code>")
		text.WriteString(html.EscapeString(module.EgressGroup))
		text.WriteString("</code>")
	}
	text.WriteString("\nCapture DNS：<code>")
	text.WriteString(html.EscapeString(botExtensionCaptureDNSLabel(module.CaptureDNS)))
	text.WriteString("</code>")
	text.WriteString("\nCapture hosts：")
	if len(module.CaptureHosts) == 0 {
		text.WriteString("<i>无</i>")
	} else {
		for _, host := range module.CaptureHosts {
			text.WriteString("\n• <code>")
			text.WriteString(html.EscapeString(host))
			text.WriteString("</code>")
		}
	}
	text.WriteString(fmt.Sprintf("\nActions：<code>%d</code> · Settings：<code>%d</code>", module.ScriptCount, len(module.Settings)))
	text.WriteString("\nAction metadata：")
	text.WriteString(botExtensionActionsHTML(module.Actions))
	text.WriteString("\nTyped settings：")
	text.WriteString(botExtensionSettingsSchemaHTML(module.Settings))
	if module.PersistentStorage {
		text.WriteString("\n权限：bounded persistent storage")
	}
	if len(module.HostMappings) > 0 {
		text.WriteString("\nUpstream mappings：")
		for _, mapping := range module.HostMappings {
			text.WriteString("\n• <code>")
			text.WriteString(html.EscapeString(mapping.Pattern + " → " + mapping.Target))
			text.WriteString("</code>")
		}
	}
	if len(module.RoutingRules) > 0 {
		text.WriteString("\nGlobal routing rules：")
		text.WriteString(botExtensionRoutingRulesHTML(module.RoutingRules))
	}
	if module.EgressGroupRequired && module.EgressGroup == "" {
		text.WriteString("\n需要管理员选择 mihomo 出口组后才能启用。")
	}
	if len(module.NetworkOrigins) > 0 {
		text.WriteString("\n\n")
		text.WriteString(botExtensionNetworkRiskHTML(module.NetworkOrigins))
	}
	return text.String()
}

func botExtensionRoutingRulesHTML(rules []interceptRoutingRule) string {
	if len(rules) == 0 {
		return "<i>无</i>"
	}
	var text strings.Builder
	for _, rule := range rules {
		body, _ := json.Marshal(rule)
		text.WriteString("\n• <code>")
		text.WriteString(html.EscapeString(string(body)))
		text.WriteString("</code>")
	}
	return text.String()
}
