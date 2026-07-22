package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"strconv"
	"strings"

	"github.com/go-telegram/bot"
	"github.com/go-telegram/bot/models"
)

func (bt *Bot) renderBotExtensionModules(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid int64,
	page int,
	notice string,
) {
	view, err := bt.ctrl.InterceptModules()
	if err != nil {
		bt.edit(ctx, b, cq, "❌ 插件管理不可用："+pre(err.Error()), botExtensionBack("market"))
		return
	}
	if _, err := bt.extensionStateStore().CancelSelectionsByKindForOperation(ctx, botExtensionPayloadModule); err != nil {
		return
	}
	if _, err := bt.extensionStateStore().CancelSelectionsByKindForOperation(ctx, botExtensionPayloadSetting); err != nil {
		return
	}
	if _, err := bt.extensionStateStore().CancelSelectionsByKindForOperation(ctx, botExtensionPayloadEgress); err != nil {
		return
	}
	if _, err := bt.extensionStateStore().CancelSelectionsByKindForOperation(ctx, botExtensionPayloadCaptureDNS); err != nil {
		return
	}
	settings, settingsErr := bt.ctrl.InterceptSettings()
	start, end, pages := pageBounds(len(view.Modules), page, botExtensionPageSize)
	page = start / botExtensionPageSize
	var text strings.Builder
	text.WriteString("<b>插件管理</b>\n所有写操作都会显示完整审查并要求短期一次性确认。")
	if settingsErr == nil {
		master := "关闭"
		if settings.Enabled {
			master = "启用"
		}
		text.WriteString("\nMITM master：<b>")
		text.WriteString(master)
		text.WriteString("</b>")
	}
	text.WriteString(fmt.Sprintf("\n已安装：<code>%d</code> · 第 <code>%d/%d</code> 页", len(view.Modules), page+1, pages))
	if notice != "" {
		text.WriteString("\n\n")
		text.WriteString(notice)
	}
	if len(view.Modules) == 0 {
		text.WriteString("\n\n尚未安装插件。")
	}

	rows := make([][]models.InlineKeyboardButton, 0, botExtensionPageSize+6)
	for index := start; index < end; index++ {
		module := view.Modules[index]
		token, _, issueErr := bt.extensionStateStore().IssueSelectionForOperation(ctx, botExtensionStatePayload{
			Kind:     botExtensionPayloadModule,
			Revision: view.Revision,
			ModuleID: module.ID,
			Digest:   module.SnapshotDigest,
		})
		if issueErr != nil {
			bt.edit(ctx, b, cq, "❌ 无法创建插件选择："+pre(issueErr.Error()), botExtensionBack("market"))
			return
		}
		state := "⚪"
		if module.Enabled && module.Ready {
			state = "🟢"
		} else if module.Enabled {
			state = "🟠"
		}
		rows = append(rows, []models.InlineKeyboardButton{botExtensionButton(
			state+" "+truncateBotExtensionLabel(module.Name, 34), "module:"+token,
		)})
	}
	if pages > 1 {
		rows = append(rows, botExtensionPageRow("modules", page, pages))
	}
	rows = append(rows,
		[]models.InlineKeyboardButton{
			botExtensionButton("🌐 从 URL 安装", "install:url"),
			botExtensionButton("📄 粘贴 YAML", "install:local"),
		},
		[]models.InlineKeyboardButton{botExtensionButton("🔐 MITM 与协议设置", "mitm")},
		[]models.InlineKeyboardButton{botExtensionButton("🛍 插件市场", "market")},
		[]models.InlineKeyboardButton{botExtensionButton("🔄 刷新", "modules")},
		[]models.InlineKeyboardButton{btn("« 返回", "menu:main")},
	)
	bt.edit(ctx, b, cq, text.String(), &models.InlineKeyboardMarkup{InlineKeyboard: rows})
}

func (bt *Bot) resolveBotExtensionModule(
	uid, chatID int64,
	token string,
) (interceptModulesView, interceptModuleView, botExtensionStatePayload, error) {
	payload, ok := bt.extensionStateStore().ResolveSelection(token, uid, chatID, botExtensionPayloadModule)
	if !ok {
		return interceptModulesView{}, interceptModuleView{}, payload, errors.New("插件选择已过期或不属于当前管理员")
	}
	view, err := bt.ctrl.InterceptModules()
	if err != nil {
		return interceptModulesView{}, interceptModuleView{}, payload, err
	}
	if view.Revision != payload.Revision {
		return view, interceptModuleView{}, payload, errInterceptRevisionConflict
	}
	for _, module := range view.Modules {
		if module.ID == payload.ModuleID && module.SnapshotDigest == payload.Digest {
			return view, module, payload, nil
		}
	}
	return view, interceptModuleView{}, payload, errors.New("插件快照已变化或已删除")
}

func (bt *Bot) renderBotExtensionModule(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid int64,
	token string,
	notice string,
) {
	view, module, _, err := bt.resolveBotExtensionModule(uid, callbackChatID(cq), token)
	if err != nil {
		bt.edit(ctx, b, cq, "⚠️ 无法打开插件："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	var text strings.Builder
	text.WriteString(botExtensionModuleDetailHTML(module))
	if notice != "" {
		text.WriteString("\n\n")
		text.WriteString(notice)
	}
	rows := make([][]models.InlineKeyboardButton, 0, 8)
	toggle := "✅ 启用"
	if module.Enabled {
		toggle = "⏹ 关闭"
	}
	rows = append(rows, []models.InlineKeyboardButton{botExtensionButton(toggle, "module:toggle:"+token)})
	if len(module.Settings) > 0 {
		rows = append(rows, []models.InlineKeyboardButton{botExtensionButton("🔧 参数", "settings:"+token+":0")})
	}
	if module.EgressGroupRequired || len(view.AvailableEgressGroups) > 0 {
		rows = append(rows, []models.InlineKeyboardButton{botExtensionButton("🚪 出口绑定", "egress:"+token+":0")})
	}
	rows = append(rows, []models.InlineKeyboardButton{botExtensionButton("🧭 Capture DNS", "capture-dns:"+token)})
	rows = append(rows, []models.InlineKeyboardButton{
		botExtensionButton("⬆️ 上移", "module:up:"+token),
		botExtensionButton("⬇️ 下移", "module:down:"+token),
	})
	if strings.TrimSpace(module.SourceURL) != "" {
		rows = append(rows, []models.InlineKeyboardButton{botExtensionButton("🔎 检查更新", "module:update:"+token)})
	}
	if !module.Enabled {
		rows = append(rows, []models.InlineKeyboardButton{botExtensionButton("🗑 卸载", "module:delete:"+token)})
	}
	rows = append(rows, []models.InlineKeyboardButton{botExtensionButton("« 返回", "modules")})
	keyboard := &models.InlineKeyboardMarkup{InlineKeyboard: rows}
	content := text.String()
	if len(content) > 4*3900 {
		bt.edit(ctx, b, cq, "<b>"+html.EscapeString(module.Name)+"</b>\n完整详情较长，已作为受保护的 HTML 文档发送。", keyboard)
		if bt.botExtensionOperationCurrent(ctx) {
			if err := sendBotExtensionDetailDocument(ctx, b, callbackChatID(cq), "5gpn-extension-detail.html",
				"📄 <b>完整插件详情</b>\n包含不可变摘要、actions、typed settings、权限、hosts、mappings、Capture DNS 与出口信息。", content); err != nil {
				bt.edit(ctx, b, cq, "❌ 完整详情文档发送失败："+pre(err.Error()), keyboard)
			}
		}
		return
	}
	bt.edit(ctx, b, cq, content, keyboard)
}

func botExtensionCaptureDNSLabel(value string) string {
	switch value {
	case interceptCaptureDNSTrust:
		return "Trust"
	case interceptCaptureDNSChina:
		return "China"
	default:
		return value
	}
}

func botExtensionModuleDetailHTML(module interceptModuleView) string {
	state := "⚪ 已关闭"
	if module.Enabled && module.Ready {
		state = "🟢 已启用"
	} else if module.Enabled {
		state = "🟠 已 armed，但运行未就绪"
	}
	var text strings.Builder
	text.WriteString("<b>")
	text.WriteString(html.EscapeString(module.Name))
	text.WriteString("</b> · <code>")
	text.WriteString(html.EscapeString(module.Version))
	text.WriteString("</code>\n")
	text.WriteString(html.EscapeString(module.Description))
	text.WriteString("\n\n状态：")
	text.WriteString(state)
	text.WriteString("\nID：<code>")
	text.WriteString(html.EscapeString(module.ID))
	text.WriteString("</code>\n执行顺序：<code>")
	text.WriteString(strconv.Itoa(module.ExecutionOrder))
	text.WriteString("</code>\n快照：<code>")
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
	if module.Reason != "" {
		text.WriteString("\n运行原因：<code>")
		text.WriteString(html.EscapeString(module.Reason))
		text.WriteString("</code>")
	}
	text.WriteString("\nCapture hosts：")
	for _, host := range module.CaptureHosts {
		text.WriteString("\n• <code>")
		text.WriteString(html.EscapeString(host))
		text.WriteString("</code>")
	}
	text.WriteString(fmt.Sprintf("\nActions：<code>%d</code> · Settings：<code>%d</code>", module.ScriptCount, len(module.Settings)))
	text.WriteString("\nAction metadata：")
	text.WriteString(botExtensionActionsHTML(module.Actions))
	text.WriteString("\nTyped settings：")
	text.WriteString(botExtensionSettingsSchemaHTML(module.Settings))
	if module.PersistentStorage {
		text.WriteString("\n权限：bounded persistent storage")
	}
	if module.EgressGroupRequired {
		text.WriteString("\n出口要求：<b>必需</b>")
	}
	if module.EgressGroup != "" {
		text.WriteString("\n当前出口：<code>")
		text.WriteString(html.EscapeString(module.EgressGroup))
		text.WriteString("</code>")
	}
	text.WriteString("\nCapture DNS：<code>")
	text.WriteString(html.EscapeString(botExtensionCaptureDNSLabel(module.CaptureDNS)))
	text.WriteString("</code>")
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
	if len(module.NetworkOrigins) > 0 {
		text.WriteString("\n\n")
		text.WriteString(botExtensionNetworkRiskHTML(module.NetworkOrigins))
	}
	return text.String()
}

func (bt *Bot) handleBotExtensionModuleCallback(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	rest string,
) {
	for _, action := range []string{"toggle", "delete", "up", "down", "update"} {
		if token, ok := strings.CutPrefix(rest, action+":"); ok {
			switch action {
			case "toggle":
				bt.previewBotExtensionToggle(ctx, b, cq, uid, chatID, token)
			case "delete":
				bt.previewBotExtensionDelete(ctx, b, cq, uid, chatID, token)
			case "up", "down":
				bt.previewBotExtensionReorder(ctx, b, cq, uid, chatID, token, action)
			case "update":
				bt.previewBotExtensionUpdate(ctx, b, cq, uid, chatID, token)
			}
			return
		}
	}
	bt.renderBotExtensionModule(ctx, b, cq, uid, rest, "")
}

func (bt *Bot) previewBotExtensionToggle(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	token string,
) {
	view, module, _, err := bt.resolveBotExtensionModule(uid, chatID, token)
	if err != nil {
		bt.edit(ctx, b, cq, "⚠️ 无法切换插件："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	next := !module.Enabled
	if next && module.Reason == "settings-required" {
		bt.renderBotExtensionModule(ctx, b, cq, uid, token, "❌ 请先在“参数”中完成所有必填 typed settings，再启用插件。")
		return
	}
	if next && (module.Reason == "egress-group-required" || module.Reason == "egress-group-missing") {
		bt.renderBotExtensionModule(ctx, b, cq, uid, token, "❌ 请先在“出口绑定”中选择 operator-owned mihomo 出口组，再启用插件。")
		return
	}
	kind := botExtensionPayloadDisable
	action := "关闭"
	impact := "这会撤销该插件的 armed 状态；若 MITM master 已启用，也会从共享事务移除其 DNS 与 mihomo capture overlay。重叠 capture host 将由执行顺序中的下一个 enabled 插件接管 mihomo origin re-resolution DNS 绑定。"
	if next {
		kind = botExtensionPayloadEnable
		action = "启用"
		impact = "这会将插件设为 armed；MITM master 开启时会发布证书、mihomo capture 规则、已审查的 REJECT/DIRECT 路由规则和 DNS 引流，并允许脚本读取命中的解密流量。重叠 capture host 的 mihomo origin re-resolution DNS 绑定按执行顺序由第一个 enabled 插件获胜；China 绑定使用运行时实时 China group 与当前 ECS 配置。"
	}
	payload := botExtensionStatePayload{
		Kind:      kind,
		Revision:  view.Revision,
		ModuleID:  module.ID,
		Digest:    module.SnapshotDigest,
		BoolValue: next,
	}
	prompt := "⚠️ <b>确认" + action + "插件？</b>\n" + botExtensionModuleDetailHTML(module) + "\n\n" + impact
	if next && len(module.NetworkOrigins) > 0 {
		prompt += "\n\n" + botExtensionNetworkRiskHTML(module.NetworkOrigins)
	}
	bt.issueBotExtensionConfirmation(ctx, b, cq, uid, chatID, payload, prompt)
}

func (bt *Bot) previewBotExtensionDelete(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	token string,
) {
	view, module, _, err := bt.resolveBotExtensionModule(uid, chatID, token)
	if err != nil {
		bt.edit(ctx, b, cq, "⚠️ 无法卸载插件："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	if module.Enabled {
		bt.renderBotExtensionModule(ctx, b, cq, uid, token, "❌ 必须先关闭插件，才能卸载其本地快照。")
		return
	}
	payload := botExtensionStatePayload{
		Kind:     botExtensionPayloadUninstall,
		Revision: view.Revision,
		ModuleID: module.ID,
		Digest:   module.SnapshotDigest,
	}
	prompt := "⚠️ <b>确认卸载插件？</b>\n" + botExtensionModuleDetailHTML(module) +
		"\n\n这会删除本地不可变快照、参数和出口绑定。插件当前已关闭；不会删除市场来源。脚本的 bounded persistent storage 独立保留，不会被卸载动作隐式擦除。"
	bt.issueBotExtensionConfirmation(ctx, b, cq, uid, chatID, payload, prompt)
}

func (bt *Bot) previewBotExtensionReorder(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	token, direction string,
) {
	view, module, _, err := bt.resolveBotExtensionModule(uid, chatID, token)
	if err != nil {
		bt.edit(ctx, b, cq, "⚠️ 无法调整顺序："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	order := append([]string(nil), view.ExecutionOrder...)
	index := -1
	for i, id := range order {
		if id == module.ID {
			index = i
			break
		}
	}
	next := index - 1
	if direction == "down" {
		next = index + 1
	}
	if index < 0 || next < 0 || next >= len(order) {
		bt.renderBotExtensionModule(ctx, b, cq, uid, token, "该插件已经位于此方向的边界。")
		return
	}
	order[index], order[next] = order[next], order[index]
	raw, _ := marshalBotExtensionMutation(botExtensionMutation{ExecutionOrder: order})
	payload := botExtensionStatePayload{
		Kind:     botExtensionPayloadReorder,
		Revision: view.Revision,
		ModuleID: module.ID,
		Digest:   module.SnapshotDigest,
		RawJSON:  raw,
	}
	prompt := "⚠️ <b>确认调整插件执行顺序？</b>\n插件：<b>" + html.EscapeString(module.Name) +
		"</b>\n当前位置：<code>" + strconv.Itoa(index+1) + "</code>\n新位置：<code>" + strconv.Itoa(next+1) +
		"</code>\n完整旧顺序：" + botExtensionExecutionOrderHTML(view, view.ExecutionOrder) +
		"\n完整新顺序：" + botExtensionExecutionOrderHTML(view, order) +
		"\n\n执行顺序同时决定 action composition、capture host 重叠时第一个生效的出口绑定、重叠 capture host 的第一个 enabled mihomo origin re-resolution DNS 绑定赢家，以及重叠全局 REJECT/DIRECT 规则的 first-match 优先级。China 绑定使用运行时实时 China group 与当前 ECS 配置。"
	bt.issueBotExtensionConfirmation(ctx, b, cq, uid, chatID, payload, prompt)
}

func botExtensionExecutionOrderHTML(view interceptModulesView, order []string) string {
	modules := make(map[string]interceptModuleView, len(view.Modules))
	for _, module := range view.Modules {
		modules[module.ID] = module
	}
	var text strings.Builder
	for index, id := range order {
		module := modules[id]
		name := module.Name
		if name == "" {
			name = id
		}
		text.WriteString("\n")
		text.WriteString(strconv.Itoa(index + 1))
		text.WriteString(". <b>")
		text.WriteString(html.EscapeString(name))
		text.WriteString("</b> · <code>")
		text.WriteString(html.EscapeString(id))
		text.WriteString("</code>")
		text.WriteString("\n   hosts=<code>")
		text.WriteString(html.EscapeString(strings.Join(module.CaptureHosts, ", ")))
		text.WriteString("</code> · egress=<code>")
		egress := module.EgressGroup
		if egress == "" {
			egress = "operator 终端目标"
		}
		text.WriteString(html.EscapeString(egress))
		text.WriteString("</code> · capture_dns=<code>")
		text.WriteString(html.EscapeString(botExtensionCaptureDNSLabel(module.CaptureDNS)))
		text.WriteString("</code> · routing_rules=<code>")
		text.WriteString(strconv.Itoa(len(module.RoutingRules)))
		text.WriteString("</code>")
		if len(module.NetworkOrigins) > 0 {
			text.WriteString("\n   ")
			text.WriteString(botExtensionNetworkRiskHTML(module.NetworkOrigins))
		}
	}
	return text.String()
}

func (bt *Bot) previewBotExtensionUpdate(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	token string,
) {
	view, module, _, err := bt.resolveBotExtensionModule(uid, chatID, token)
	if err != nil {
		bt.edit(ctx, b, cq, "⚠️ 无法检查更新："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	if module.Enabled {
		bt.renderBotExtensionModule(ctx, b, cq, uid, token, "❌ 必须先关闭插件，才能检查并应用不可变快照更新。")
		return
	}
	bt.edit(ctx, b, cq, "⏳ 正在安全获取并验证更新候选…", nil)
	release, err := bt.acquireBotExtensionFetch(ctx)
	if err != nil {
		return
	}
	check, err := bt.ctrl.CheckInterceptModuleUpdate(ctx, module.ID, view.Revision)
	release()
	if err != nil {
		bt.edit(ctx, b, cq, "❌ 更新检查失败："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	if check.State == "unchanged" || check.Candidate == nil {
		bt.renderBotExtensionModules(ctx, b, cq, uid, 0, "✅ 当前不可变插件快照已经是最新版本。")
		return
	}
	candidate := *check.Candidate
	payload := botExtensionStatePayload{
		Kind:            botExtensionPayloadUpdate,
		Revision:        view.Revision,
		ModuleID:        module.ID,
		Digest:          module.SnapshotDigest,
		CandidateDigest: candidate.SnapshotDigest,
	}
	prompt := "⚠️ <b>确认应用插件更新？</b>\n<b>当前已安装快照</b>\n" + botExtensionModuleDetailHTML(module) +
		"\n\n<b>候选快照</b>\n" + botExtensionCandidateReviewHTML(candidate) +
		"\n\n" + botExtensionChangedSettingsHTML(module.Settings, candidate.Settings) +
		"\n\n确认时会重新获取并要求候选快照摘要完全一致。更新应用后插件保持关闭。"
	bt.issueBotExtensionConfirmation(ctx, b, cq, uid, chatID, payload, prompt)
}

func botExtensionChangedSettingsHTML(current, candidate []interceptModuleSetting) string {
	currentByKey := make(map[string]interceptModuleSetting, len(current))
	candidateByKey := make(map[string]interceptModuleSetting, len(candidate))
	for _, setting := range current {
		currentByKey[setting.Key] = setting
	}
	for _, setting := range candidate {
		candidateByKey[setting.Key] = setting
	}
	changes := make([]string, 0)
	for _, setting := range candidate {
		previous, existed := currentByKey[setting.Key]
		if !existed {
			changes = append(changes, "新增 <code>"+html.EscapeString(setting.Key)+"</code> · <code>"+html.EscapeString(setting.Type)+"</code>")
			continue
		}
		previous.Value = nil
		next := setting
		next.Value = nil
		previousJSON, _ := json.Marshal(previous)
		nextJSON, _ := json.Marshal(next)
		if string(previousJSON) != string(nextJSON) {
			changes = append(changes, "约束/默认值变化 <code>"+html.EscapeString(setting.Key)+"</code> · <code>"+html.EscapeString(previous.Type)+" → "+html.EscapeString(setting.Type)+"</code>")
		}
	}
	for _, setting := range current {
		if _, exists := candidateByKey[setting.Key]; !exists {
			changes = append(changes, "删除 <code>"+html.EscapeString(setting.Key)+"</code> · 原类型 <code>"+html.EscapeString(setting.Type)+"</code>")
		}
	}
	if len(changes) == 0 {
		return "Typed settings 变化：<i>无</i>"
	}
	return "<b>Typed settings 变化</b>\n• " + strings.Join(changes, "\n• ")
}

func (bt *Bot) handleBotExtensionSettingsCallback(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	rest string,
) {
	token, rawPage, ok := strings.Cut(rest, ":")
	if !ok {
		bt.edit(ctx, b, cq, "参数分页无效。", botExtensionBack("modules"))
		return
	}
	page, valid := handleBotExtensionPage(rawPage)
	if !valid {
		bt.edit(ctx, b, cq, "参数分页无效。", botExtensionBack("modules"))
		return
	}
	view, module, _, err := bt.resolveBotExtensionModule(uid, chatID, token)
	if err != nil {
		bt.edit(ctx, b, cq, "⚠️ 无法打开参数："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	start, end, pages := pageBounds(len(module.Settings), page, 6)
	page = start / 6
	if _, err := bt.extensionStateStore().CancelSelectionsByKindForOperation(ctx, botExtensionPayloadSetting); err != nil {
		return
	}
	text := "<b>" + html.EscapeString(module.Name) + " · 参数</b>\n修改时必须提交并验证完整 settings map，未编辑的值也会保持原样。"
	rows := make([][]models.InlineKeyboardButton, 0, 9)
	for index := start; index < end; index++ {
		setting := module.Settings[index]
		settingToken, _, issueErr := bt.extensionStateStore().IssueSelectionForOperation(ctx, botExtensionStatePayload{
			Kind:       botExtensionPayloadSetting,
			Revision:   view.Revision,
			ModuleID:   module.ID,
			SettingKey: setting.Key,
			Digest:     module.SnapshotDigest,
		})
		if issueErr != nil {
			bt.edit(ctx, b, cq, "❌ 无法创建参数选择："+pre(issueErr.Error()), botExtensionBack("modules"))
			return
		}
		label := setting.Label
		if strings.TrimSpace(label) == "" {
			label = setting.Key
		}
		rows = append(rows, []models.InlineKeyboardButton{botExtensionButton(
			truncateBotExtensionLabel(label, 36), "setting:"+settingToken,
		)})
	}
	if pages > 1 {
		rows = append(rows, botExtensionSettingsPageRow(token, page, pages))
	}
	rows = append(rows, []models.InlineKeyboardButton{botExtensionButton("« 返回", "module:"+token)})
	bt.edit(ctx, b, cq, text, &models.InlineKeyboardMarkup{InlineKeyboard: rows})
}

func botExtensionSettingsPageRow(token string, page, pages int) []models.InlineKeyboardButton {
	row := make([]models.InlineKeyboardButton, 0, 3)
	if page > 0 {
		row = append(row, botExtensionButton("‹ 上一页", "settings:"+token+":"+strconv.Itoa(page-1)))
	}
	row = append(row, botExtensionButton(fmt.Sprintf("%d/%d", page+1, pages), "settings:"+token+":"+strconv.Itoa(page)))
	if page+1 < pages {
		row = append(row, botExtensionButton("下一页 ›", "settings:"+token+":"+strconv.Itoa(page+1)))
	}
	return row
}

func (bt *Bot) resolveBotExtensionSetting(
	uid, chatID int64,
	token string,
) (interceptModulesView, interceptModuleView, interceptModuleSetting, botExtensionStatePayload, error) {
	payload, ok := bt.extensionStateStore().ResolveSelection(token, uid, chatID, botExtensionPayloadSetting)
	if !ok {
		return interceptModulesView{}, interceptModuleView{}, interceptModuleSetting{}, payload, errors.New("参数选择已过期或不属于当前管理员")
	}
	view, err := bt.ctrl.InterceptModules()
	if err != nil {
		return interceptModulesView{}, interceptModuleView{}, interceptModuleSetting{}, payload, err
	}
	if view.Revision != payload.Revision {
		return view, interceptModuleView{}, interceptModuleSetting{}, payload, errInterceptRevisionConflict
	}
	for _, module := range view.Modules {
		if module.ID != payload.ModuleID || module.SnapshotDigest != payload.Digest {
			continue
		}
		for _, setting := range module.Settings {
			if setting.Key == payload.SettingKey {
				return view, module, setting, payload, nil
			}
		}
	}
	return view, interceptModuleView{}, interceptModuleSetting{}, payload, errors.New("插件参数或快照已变化")
}

func (bt *Bot) handleBotExtensionSettingCallback(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	rest string,
) {
	if token, ok := strings.CutPrefix(rest, "edit:"); ok {
		bt.beginBotExtensionSettingInput(ctx, b, cq, uid, chatID, token)
		return
	}
	if token, ok := strings.CutPrefix(rest, "value:"); ok {
		bt.previewBotExtensionSettingSelection(ctx, b, cq, uid, chatID, token)
		return
	}
	token := rest
	page := 0
	if head, rawPage, ok := strings.Cut(rest, ":"); ok {
		token = head
		var valid bool
		page, valid = handleBotExtensionPage(rawPage)
		if !valid {
			bt.edit(ctx, b, cq, "参数选项分页无效。", botExtensionBack("modules"))
			return
		}
	}
	view, module, setting, payload, err := bt.resolveBotExtensionSetting(uid, chatID, token)
	if err != nil {
		bt.edit(ctx, b, cq, "⚠️ 无法打开参数："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	_ = view
	if _, err := bt.extensionStateStore().CancelSelectionsByKindForOperation(ctx, botExtensionPayloadSetting); err != nil {
		return
	}
	payload.StringValue = ""
	payload.RawJSON = nil
	baseToken, _, err := bt.extensionStateStore().IssueSelectionForOperation(ctx, payload)
	if err != nil {
		bt.edit(ctx, b, cq, "❌ 无法创建参数菜单："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	label := setting.Label
	if strings.TrimSpace(label) == "" {
		label = setting.Key
	}
	var text strings.Builder
	text.WriteString("<b>")
	text.WriteString(html.EscapeString(label))
	text.WriteString("</b>\nKey：<code>")
	text.WriteString(html.EscapeString(setting.Key))
	text.WriteString("</code> · 类型：<code>")
	text.WriteString(html.EscapeString(setting.Type))
	text.WriteString("</code>")
	if setting.Required {
		text.WriteString(" · <b>必填</b>")
	}
	if setting.Description != "" {
		text.WriteString("\n")
		text.WriteString(html.EscapeString(setting.Description))
	}
	text.WriteString("\n当前值：")
	text.WriteString(botExtensionSettingValueHTML(setting))

	rows := make([][]models.InlineKeyboardButton, 0, 12)
	switch setting.Type {
	case "select":
		start, end, pages := pageBounds(len(setting.Options), page, 8)
		page = start / 8
		text.WriteString(fmt.Sprintf("\n选项第 <code>%d/%d</code> 页", page+1, pages))
		for _, option := range setting.Options[start:end] {
			raw, _ := json.Marshal(option)
			valueToken, issueErr := bt.issueBotExtensionSettingValueSelection(ctx, payload, raw)
			if issueErr != nil {
				bt.edit(ctx, b, cq, "❌ 无法创建参数选项："+pre(issueErr.Error()), botExtensionBack("modules"))
				return
			}
			rows = append(rows, []models.InlineKeyboardButton{botExtensionButton(
				truncateBotExtensionLabel(option, 38), "setting:value:"+valueToken,
			)})
		}
		if pages > 1 {
			rows = append(rows, botExtensionSettingOptionsPageRow(baseToken, page, pages))
		}
	case "boolean":
		for _, option := range []struct {
			label string
			raw   json.RawMessage
		}{{"开启 / true", json.RawMessage("true")}, {"关闭 / false", json.RawMessage("false")}} {
			valueToken, issueErr := bt.issueBotExtensionSettingValueSelection(ctx, payload, option.raw)
			if issueErr != nil {
				bt.edit(ctx, b, cq, "❌ 无法创建参数选项："+pre(issueErr.Error()), botExtensionBack("modules"))
				return
			}
			rows = append(rows, []models.InlineKeyboardButton{botExtensionButton(option.label, "setting:value:"+valueToken)})
		}
	default:
		rows = append(rows, []models.InlineKeyboardButton{botExtensionButton("✏️ 输入新值", "setting:edit:"+baseToken)})
	}
	if !setting.Required {
		valueToken, issueErr := bt.issueBotExtensionSettingValueSelection(ctx, payload, json.RawMessage("null"))
		if issueErr == nil {
			rows = append(rows, []models.InlineKeyboardButton{botExtensionButton("清除可选值", "setting:value:"+valueToken)})
		}
	}
	moduleToken, _, issueErr := bt.extensionStateStore().IssueSelectionForOperation(ctx, botExtensionStatePayload{
		Kind:     botExtensionPayloadModule,
		Revision: payload.Revision,
		ModuleID: module.ID,
		Digest:   module.SnapshotDigest,
	})
	if issueErr == nil {
		rows = append(rows, []models.InlineKeyboardButton{botExtensionButton("« 返回参数", "settings:"+moduleToken+":0")})
	} else {
		rows = append(rows, []models.InlineKeyboardButton{botExtensionButton("« 返回", "modules")})
	}
	keyboard := &models.InlineKeyboardMarkup{InlineKeyboard: rows}
	content := text.String()
	if len(content) > 4*3900 {
		bt.edit(ctx, b, cq, "<b>"+html.EscapeString(module.Name)+" · "+html.EscapeString(label)+"</b>\n完整参数详情较长，已作为受保护的 HTML 文档发送。", keyboard)
		if bt.botExtensionOperationCurrent(ctx) {
			if err := sendBotExtensionDetailDocument(ctx, b, callbackChatID(cq), "5gpn-extension-setting.html",
				"📄 <b>完整插件参数详情</b>", content); err != nil {
				bt.edit(ctx, b, cq, "❌ 完整参数文档发送失败："+pre(err.Error()), keyboard)
			}
		}
		return
	}
	bt.edit(ctx, b, cq, content, keyboard)
}

func botExtensionSettingOptionsPageRow(token string, page, pages int) []models.InlineKeyboardButton {
	row := make([]models.InlineKeyboardButton, 0, 3)
	if page > 0 {
		row = append(row, botExtensionButton("‹ 上一页", "setting:"+token+":"+strconv.Itoa(page-1)))
	}
	row = append(row, botExtensionButton(fmt.Sprintf("%d/%d", page+1, pages), "setting:"+token+":"+strconv.Itoa(page)))
	if page+1 < pages {
		row = append(row, botExtensionButton("下一页 ›", "setting:"+token+":"+strconv.Itoa(page+1)))
	}
	return row
}

func (bt *Bot) issueBotExtensionSettingValueSelection(
	ctx context.Context,
	base botExtensionStatePayload,
	value json.RawMessage,
) (string, error) {
	base.StringValue = "proposed"
	base.RawJSON = append(json.RawMessage(nil), value...)
	token, _, err := bt.extensionStateStore().IssueSelectionForOperation(ctx, base)
	return token, err
}

func (bt *Bot) beginBotExtensionSettingInput(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	token string,
) {
	_, _, setting, payload, err := bt.resolveBotExtensionSetting(uid, chatID, token)
	if err != nil {
		bt.edit(ctx, b, cq, "⚠️ 无法编辑参数："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	kind := botExtensionInputSettingText
	instruction := "请发送新的文本值。"
	switch setting.Type {
	case "text":
	case "number":
		kind = botExtensionInputSettingNumber
		instruction = "请发送有限数值。"
	case "location":
		kind = botExtensionInputSettingLocation
		instruction = "请用 Telegram 附件菜单发送一个位置，或发送 <code>longitude,latitude,accuracy</code>。\n⚠️ 坐标会经过 Telegram 与 Telegram Bot API；收到后机器人会先发送受保护的地图点预览，再提供确认。Telegram 未提供精度时按保守的 <code>100000m</code> 保存，可改用手工格式调整。"
	default:
		bt.edit(ctx, b, cq, "该参数请使用上方预定义选项。", botExtensionBack("modules"))
		return
	}
	_, err = bt.extensionStateStore().BeginInputForOperation(ctx, kind, payload)
	if err != nil {
		bt.edit(ctx, b, cq, "❌ 无法开始参数输入："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	bt.edit(ctx, b, cq, instruction+"\n发送 /cancel 可取消。", botExtensionBack("modules"))
}

func (bt *Bot) previewBotExtensionSettingSelection(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	token string,
) {
	view, module, setting, payload, err := bt.resolveBotExtensionSetting(uid, chatID, token)
	if err != nil || payload.StringValue != "proposed" {
		if err == nil {
			err = errors.New("参数选项状态无效")
		}
		bt.edit(ctx, b, cq, "⚠️ 无法应用参数选项："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	bt.issueBotExtensionSettingConfirmation(ctx, b, cq, uid, chatID, view, module, setting, payload.RawJSON)
}

func (bt *Bot) issueBotExtensionSettingConfirmation(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	view interceptModulesView,
	module interceptModuleView,
	setting interceptModuleSetting,
	value json.RawMessage,
) {
	settings, err := buildBotExtensionSettings(module.Settings, setting.Key, value)
	if err != nil {
		bt.edit(ctx, b, cq, "❌ 参数值无效："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	raw, err := marshalBotExtensionMutation(botExtensionMutation{Settings: settings})
	if err != nil {
		bt.edit(ctx, b, cq, "❌ 无法准备参数确认："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	payload := botExtensionStatePayload{
		Kind:       botExtensionPayloadSetting,
		Revision:   view.Revision,
		ModuleID:   module.ID,
		SettingKey: setting.Key,
		Digest:     module.SnapshotDigest,
		RawJSON:    raw,
	}
	prompt := botExtensionSettingReviewHTML(module, setting, value) +
		"\n\n提交内容包含该插件的完整 settings map；其他参数保持当前值。"
	bt.issueBotExtensionConfirmation(ctx, b, cq, uid, chatID, payload, prompt)
}

func botExtensionSettingReviewHTML(module interceptModuleView, setting interceptModuleSetting, value json.RawMessage) string {
	prompt := "插件：<b>" + html.EscapeString(module.Name) + "</b>\nID：<code>" +
		html.EscapeString(module.ID) + "</code>\n快照：<code>" + html.EscapeString(module.SnapshotDigest) +
		"</code>\n\n" + botExtensionSettingConfirmationHTML(setting, value)
	if len(module.NetworkOrigins) > 0 {
		prompt += "\n\n" + botExtensionNetworkRiskHTML(module.NetworkOrigins)
	}
	return prompt
}

func (bt *Bot) handleBotExtensionEgressCallback(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	rest string,
) {
	if token, ok := strings.CutPrefix(rest, "set:"); ok {
		bt.previewBotExtensionEgressSelection(ctx, b, cq, uid, chatID, token)
		return
	}
	moduleToken, rawPage, ok := strings.Cut(rest, ":")
	if !ok {
		bt.edit(ctx, b, cq, "出口分页无效。", botExtensionBack("modules"))
		return
	}
	page, valid := handleBotExtensionPage(rawPage)
	if !valid {
		bt.edit(ctx, b, cq, "出口分页无效。", botExtensionBack("modules"))
		return
	}
	view, module, base, err := bt.resolveBotExtensionModule(uid, chatID, moduleToken)
	if err != nil {
		bt.edit(ctx, b, cq, "⚠️ 无法打开出口绑定："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	if _, err := bt.extensionStateStore().CancelSelectionsByKindForOperation(ctx, botExtensionPayloadEgress); err != nil {
		return
	}
	groups := append([]string(nil), view.AvailableEgressGroups...)
	if !module.EgressGroupRequired {
		groups = append([]string{""}, groups...)
	}
	start, end, pages := pageBounds(len(groups), page, 6)
	page = start / 6
	text := "<b>" + html.EscapeString(module.Name) + " · 出口绑定</b>\n这里只能选择 operator-owned mihomo 中现有的受限组列表；插件 manifest 和脚本不能命名或改变出口组。"
	rows := make([][]models.InlineKeyboardButton, 0, 9)
	for index := start; index < end; index++ {
		group := groups[index]
		selection := botExtensionStatePayload{
			Kind:        botExtensionPayloadEgress,
			Revision:    view.Revision,
			ModuleID:    module.ID,
			Digest:      module.SnapshotDigest,
			StringValue: group,
		}
		token, _, issueErr := bt.extensionStateStore().IssueSelectionForOperation(ctx, selection)
		if issueErr != nil {
			bt.edit(ctx, b, cq, "❌ 无法创建出口选择："+pre(issueErr.Error()), botExtensionBack("modules"))
			return
		}
		label := group
		if group == "" {
			label = "不绑定（使用 operator terminal target）"
		}
		if group == module.EgressGroup {
			label = "✓ " + label
		}
		rows = append(rows, []models.InlineKeyboardButton{botExtensionButton(truncateBotExtensionLabel(label, 40), "egress:set:"+token)})
	}
	if pages > 1 {
		rows = append(rows, botExtensionEgressPageRow(moduleToken, page, pages))
	}
	rows = append(rows, []models.InlineKeyboardButton{botExtensionButton("« 返回", "module:"+moduleToken)})
	bt.edit(ctx, b, cq, text, &models.InlineKeyboardMarkup{InlineKeyboard: rows})
	_ = base
}

func botExtensionEgressPageRow(token string, page, pages int) []models.InlineKeyboardButton {
	row := make([]models.InlineKeyboardButton, 0, 3)
	if page > 0 {
		row = append(row, botExtensionButton("‹ 上一页", "egress:"+token+":"+strconv.Itoa(page-1)))
	}
	row = append(row, botExtensionButton(fmt.Sprintf("%d/%d", page+1, pages), "egress:"+token+":"+strconv.Itoa(page)))
	if page+1 < pages {
		row = append(row, botExtensionButton("下一页 ›", "egress:"+token+":"+strconv.Itoa(page+1)))
	}
	return row
}

func (bt *Bot) previewBotExtensionEgressSelection(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	token string,
) {
	payload, ok := bt.extensionStateStore().ResolveSelection(token, uid, chatID, botExtensionPayloadEgress)
	if !ok {
		bt.edit(ctx, b, cq, "⚠️ 出口选择已过期或不属于当前管理员。", botExtensionBack("modules"))
		return
	}
	view, module, err := requireBotExtensionModule(bt, payload)
	if err != nil {
		bt.edit(ctx, b, cq, "⚠️ 插件状态已变化："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	allowed := payload.StringValue == ""
	for _, group := range view.AvailableEgressGroups {
		if group == payload.StringValue {
			allowed = true
		}
	}
	if !allowed || (module.EgressGroupRequired && payload.StringValue == "") {
		bt.edit(ctx, b, cq, "❌ 所选出口不再可用或该插件要求显式绑定。", botExtensionBack("modules"))
		return
	}
	payload.Kind = botExtensionPayloadEgress
	label := payload.StringValue
	if label == "" {
		label = "不绑定"
	}
	prompt := "⚠️ <b>确认修改插件出口绑定？</b>\n插件：<b>" + html.EscapeString(module.Name) +
		"</b>\nID：<code>" + html.EscapeString(module.ID) + "</code>\n快照：<code>" + html.EscapeString(module.SnapshotDigest) +
		"</code>\n执行位置：<code>" + strconv.Itoa(module.ExecutionOrder) + "</code>\nCapture hosts：<code>" +
		html.EscapeString(strings.Join(module.CaptureHosts, ", ")) + "</code>\n当前：<code>" + html.EscapeString(module.EgressGroup) + "</code>\n新值：<code>" + html.EscapeString(label) +
		"</code>\n\n执行顺序决定重叠 capture host 的第一个出口赢家。"
	if len(module.NetworkOrigins) > 0 {
		prompt += "\n\n" + botExtensionNetworkRiskHTML(module.NetworkOrigins)
	}
	bt.issueBotExtensionConfirmation(ctx, b, cq, uid, chatID, payload, prompt)
}

func (bt *Bot) handleBotExtensionCaptureDNSCallback(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	rest string,
) {
	if token, ok := strings.CutPrefix(rest, "set:"); ok {
		bt.previewBotExtensionCaptureDNSSelection(ctx, b, cq, uid, chatID, token)
		return
	}
	view, module, _, err := bt.resolveBotExtensionModule(uid, chatID, rest)
	if err != nil {
		bt.edit(ctx, b, cq, "⚠️ 无法打开 Capture DNS 绑定："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	if _, err := bt.extensionStateStore().CancelSelectionsByKindForOperation(ctx, botExtensionPayloadCaptureDNS); err != nil {
		return
	}
	text := "<b>" + html.EscapeString(module.Name) + " · Capture DNS</b>\n" +
		"选择 active capture host 在 mihomo 经 <code>127.0.0.1:5354</code> 重新解析 origin 时使用的 DNS group。该设置不改变客户端 DNS policy、网关引流或 mihomo 应用出口。\n" +
		"• <b>Trust</b>：使用运行时当前 Trust group。\n" +
		"• <b>China</b>：使用运行时实时 China group 与当前 ECS 配置；China upstream 或 ECS 更新会立即影响后续解析。"
	rows := make([][]models.InlineKeyboardButton, 0, 3)
	for _, resolver := range []string{interceptCaptureDNSTrust, interceptCaptureDNSChina} {
		selection := botExtensionStatePayload{
			Kind:        botExtensionPayloadCaptureDNS,
			Revision:    view.Revision,
			ModuleID:    module.ID,
			Digest:      module.SnapshotDigest,
			StringValue: resolver,
		}
		token, _, issueErr := bt.extensionStateStore().IssueSelectionForOperation(ctx, selection)
		if issueErr != nil {
			bt.edit(ctx, b, cq, "❌ 无法创建 Capture DNS 选择："+pre(issueErr.Error()), botExtensionBack("modules"))
			return
		}
		label := botExtensionCaptureDNSLabel(resolver)
		if resolver == module.CaptureDNS {
			label = "✓ " + label
		}
		rows = append(rows, []models.InlineKeyboardButton{botExtensionButton(label, "capture-dns:set:"+token)})
	}
	rows = append(rows, []models.InlineKeyboardButton{botExtensionButton("« 返回", "module:"+rest)})
	bt.edit(ctx, b, cq, text, &models.InlineKeyboardMarkup{InlineKeyboard: rows})
}

func (bt *Bot) previewBotExtensionCaptureDNSSelection(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	token string,
) {
	payload, ok := bt.extensionStateStore().ResolveSelection(token, uid, chatID, botExtensionPayloadCaptureDNS)
	if !ok {
		bt.edit(ctx, b, cq, "⚠️ Capture DNS 选择已过期或不属于当前管理员。", botExtensionBack("modules"))
		return
	}
	view, module, err := requireBotExtensionModule(bt, payload)
	if err != nil {
		bt.edit(ctx, b, cq, "⚠️ 插件状态已变化："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	if err := validateInterceptCaptureDNS(payload.StringValue); err != nil {
		bt.edit(ctx, b, cq, "❌ Capture DNS 选择无效："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	payload.Kind = botExtensionPayloadCaptureDNS
	prompt := "⚠️ <b>确认修改插件 Capture DNS？</b>\n" + botExtensionModuleDetailHTML(module) +
		"\n\n当前绑定：<code>" + html.EscapeString(botExtensionCaptureDNSLabel(module.CaptureDNS)) +
		"</code>\n新绑定：<code>" + html.EscapeString(botExtensionCaptureDNSLabel(payload.StringValue)) +
		"</code>\n配置 revision：<code>" + html.EscapeString(view.Revision) +
		"</code>\n执行位置：<code>" + strconv.Itoa(module.ExecutionOrder) + "</code>\n" +
		"Trust 使用运行时当前 Trust group；China 使用运行时实时 China group 与当前 ECS 配置。\n" +
		"该选择只控制 active capture host 的 mihomo loopback origin re-resolution，不改变客户端 DNS policy、网关引流或 mihomo 应用出口。\n" +
		"若多个 enabled 插件声明重叠 capture host，执行顺序中的第一个插件是 DNS 绑定赢家。"
	bt.issueBotExtensionConfirmation(ctx, b, cq, uid, chatID, payload, prompt)
}

func botExtensionMITMDigest(settings interceptSettingsView) string {
	body, _ := json.Marshal(interceptMITMSettings{
		Enabled:                settings.Enabled,
		HTTP2:                  settings.HTTP2,
		QUICFallbackProtection: settings.QUICFallbackProtection,
	})
	return sha256Hex(body)
}

func (bt *Bot) renderBotExtensionMITM(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid int64,
	notice string,
) {
	settings, err := bt.ctrl.InterceptSettings()
	if err != nil {
		bt.edit(ctx, b, cq, "❌ MITM 设置不可用："+pre(err.Error()), botExtensionBack("modules"))
		return
	}
	state := func(value bool) string {
		if value {
			return "开启"
		}
		return "关闭"
	}
	text := "<b>MITM 与协议设置</b>\n" +
		"MITM master：<b>" + state(settings.Enabled) + "</b>\n" +
		"HTTP/2：<b>" + state(settings.HTTP2) + "</b>\n" +
		"QUIC fallback protection：<b>" + state(settings.QUICFallbackProtection) + "</b>"
	if notice != "" {
		text += "\n\n" + notice
	}
	rows := [][]models.InlineKeyboardButton{
		{botExtensionButton("切换 MITM master", "mitm:master")},
		{botExtensionButton("切换 HTTP/2", "mitm:http2")},
		{botExtensionButton("切换 QUIC fallback", "mitm:quic")},
		{botExtensionButton("« 返回", "modules")},
	}
	_ = uid
	bt.edit(ctx, b, cq, text, &models.InlineKeyboardMarkup{InlineKeyboard: rows})
}

func (bt *Bot) handleBotExtensionMITMCallback(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	uid, chatID int64,
	field string,
) {
	if field != "master" && field != "http2" && field != "quic" {
		bt.edit(ctx, b, cq, "MITM 设置操作无效。", botExtensionBack("mitm"))
		return
	}
	settings, err := bt.ctrl.InterceptSettings()
	if err != nil {
		bt.edit(ctx, b, cq, "❌ MITM 设置不可用："+pre(err.Error()), botExtensionBack("mitm"))
		return
	}
	next := interceptMITMSettings{
		Enabled:                settings.Enabled,
		HTTP2:                  settings.HTTP2,
		QUICFallbackProtection: settings.QUICFallbackProtection,
	}
	var prompt string
	switch field {
	case "master":
		next.Enabled = !next.Enabled
	case "http2":
		next.HTTP2 = !next.HTTP2
	case "quic":
		next.QUICFallbackProtection = !next.QUICFallbackProtection
	}
	prompt, err = bt.botExtensionMITMReview(settings.Revision, field, next)
	if err != nil {
		bt.edit(ctx, b, cq, "❌ 无法完整审查 armed 插件，未创建确认："+pre(err.Error()), botExtensionBack("mitm"))
		return
	}
	raw, err := marshalBotExtensionMutation(botExtensionMutation{MITM: &next})
	if err != nil {
		bt.edit(ctx, b, cq, "❌ 无法准备 MITM 确认："+pre(err.Error()), botExtensionBack("mitm"))
		return
	}
	payload := botExtensionStatePayload{
		Kind:       botExtensionPayloadMITM,
		Revision:   settings.Revision,
		Digest:     botExtensionMITMDigest(settings),
		SettingKey: field,
		RawJSON:    raw,
	}
	bt.issueBotExtensionConfirmation(ctx, b, cq, uid, chatID, payload, prompt)
}

func (bt *Bot) botExtensionMITMReview(revision, field string, next interceptMITMSettings) (string, error) {
	view, err := bt.ctrl.InterceptModules()
	if err != nil {
		return "", err
	}
	if view.Revision != revision {
		return "", errInterceptRevisionConflict
	}
	var text strings.Builder
	switch field {
	case "master":
		if next.Enabled {
			text.WriteString("⚠️ <b>确认开启 MITM master？</b>\n这会对所有已经 armed 的插件启动共享证书、mihomo capture rules、DNS overlay 与 sidecar transaction。")
		} else {
			text.WriteString("⚠️ <b>确认关闭 MITM master？</b>\n这会撤销下列 armed 插件当前发布的 DNS overlay 和 mihomo capture rules，并停止 sidecar 流量接管；不可变快照、参数、出口绑定与 armed 状态保留。")
		}
	case "http2":
		text.WriteString("⚠️ <b>确认切换 HTTP/2？</b>\n新值：<code>" + strconv.FormatBool(next.HTTP2) + "</code>\n这会同时控制新连接的客户端 HTTP/2 协商和上游 HTTP/2 尝试；关闭后只使用 HTTP/1.1。")
	case "quic":
		text.WriteString("⚠️ <b>确认切换 QUIC fallback protection？</b>\n新值：<code>" + strconv.FormatBool(next.QUICFallbackProtection) + "</code>\n开启时，已经被 active extension capture rules 选中的 IETF QUIC v1/v2 会被丢弃，让支持回退的客户端重试 TCP/HTTPS；其他变体不保证回退。")
	default:
		return "", errors.New("unsupported MITM review field")
	}
	if field == "master" && !next.Enabled {
		text.WriteString("\n当前 active capture hosts：")
		if len(view.ActiveCaptureHosts) == 0 {
			text.WriteString("<i>无</i>")
		} else {
			for _, host := range view.ActiveCaptureHosts {
				text.WriteString("\n• <code>")
				text.WriteString(html.EscapeString(host))
				text.WriteString("</code>")
			}
		}
	}
	text.WriteString("\n\n<b>受影响的 armed 插件完整审查</b>")
	armed := 0
	for _, module := range view.Modules {
		if !module.Enabled {
			continue
		}
		armed++
		text.WriteString("\n\n")
		text.WriteString(botExtensionModuleDetailHTML(module))
	}
	if armed == 0 {
		text.WriteString("\n当前没有 armed 插件；该设置暂时不会改变插件流量。")
	}
	return text.String(), nil
}
