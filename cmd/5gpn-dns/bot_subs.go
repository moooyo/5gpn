package main

import (
	"context"
	"fmt"
	"html"
	"strings"
	"time"

	"github.com/go-telegram/bot/models"
)

// subDraft is the per-chat add-subscription wizard state. The wizard collects
// category (button) → format (button) → name (text) → url (text), then builds a
// Subscription (ID = name, Interval = 24h, Enabled = true) and validates/adds it.
type subDraft struct {
	category string
	format   string
	name     string
}

func (bt *Bot) setSubDraft(chatID int64, d *subDraft) {
	bt.mu.Lock()
	defer bt.mu.Unlock()
	bt.subDrafts[chatID] = d
}

func (bt *Bot) getSubDraft(chatID int64) *subDraft {
	bt.mu.Lock()
	defer bt.mu.Unlock()
	return bt.subDrafts[chatID]
}

func (bt *Bot) clearSubDraft(chatID int64) {
	bt.mu.Lock()
	defer bt.mu.Unlock()
	delete(bt.subDrafts, chatID)
}

// --------------------------------------------------------------------------- //
// Keyboards
// --------------------------------------------------------------------------- //

var subCategories = []string{"adblock", "direct", "blacklist", "chnroute"}
var subFormats = []string{"plain", "gfwlist", "dnsmasq", "adblock", "hosts", "cidr"}

// subsMenu lists one button per subscription (enabled/paused icon + name) plus
// an add button and a back button.
func subsMenu(views []SubscriptionView) *models.InlineKeyboardMarkup {
	rows := make([][]models.InlineKeyboardButton, 0, len(views)+2)
	for _, v := range views {
		icon := "▶️"
		if !v.Enabled {
			icon = "⏸"
		}
		rows = append(rows, []models.InlineKeyboardButton{btn(icon+" "+v.Name, "subview:"+v.ID)})
	}
	rows = append(rows, []models.InlineKeyboardButton{btn("➕ 新增订阅", "sub:add")})
	rows = append(rows, []models.InlineKeyboardButton{btn("« 返回", "menu:main")})
	return &models.InlineKeyboardMarkup{InlineKeyboard: rows}
}

// subDetailKB is the per-subscription action row: refresh, enable/disable,
// delete, back.
func subDetailKB(v SubscriptionView) *models.InlineKeyboardMarkup {
	toggle := "⏸ 停用"
	if !v.Enabled {
		toggle = "▶️ 启用"
	}
	return &models.InlineKeyboardMarkup{InlineKeyboard: [][]models.InlineKeyboardButton{
		{btn("🔄 刷新", "subref:"+v.ID), btn(toggle, "subtog:"+v.ID)},
		{btn("🗑 删除", "subdel:"+v.ID)},
		{btn("« 返回", "menu:subs")},
	}}
}

func categoryPickerKB() *models.InlineKeyboardMarkup {
	rows := make([][]models.InlineKeyboardButton, 0, len(subCategories)+1)
	for _, c := range subCategories {
		rows = append(rows, []models.InlineKeyboardButton{btn(c, "subcat:"+c)})
	}
	rows = append(rows, []models.InlineKeyboardButton{btn("« 取消", "menu:subs")})
	return &models.InlineKeyboardMarkup{InlineKeyboard: rows}
}

func formatPickerKB() *models.InlineKeyboardMarkup {
	var rows [][]models.InlineKeyboardButton
	var row []models.InlineKeyboardButton
	for i, f := range subFormats {
		row = append(row, btn(f, "subfmt:"+f))
		if len(row) == 2 || i == len(subFormats)-1 {
			rows = append(rows, row)
			row = nil
		}
	}
	rows = append(rows, []models.InlineKeyboardButton{btn("« 取消", "menu:subs")})
	return &models.InlineKeyboardMarkup{InlineKeyboard: rows}
}

// --------------------------------------------------------------------------- //
// Rendering (pure)
// --------------------------------------------------------------------------- //

// subFirstLine returns the first line of s, truncated for a Telegram cell.
func subFirstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	if len(s) > 120 {
		s = s[:120] + "…"
	}
	return s
}

func renderSubsList(views []SubscriptionView) string {
	if len(views) == 0 {
		return "<b>📚 订阅</b>\n\n（暂无订阅，点 ➕ 新增订阅）"
	}
	var b strings.Builder
	b.WriteString("<b>📚 订阅</b>\n")
	for _, v := range views {
		status := "▶️"
		if !v.Enabled {
			status = "⏸"
		}
		health := "—"
		if v.Health != nil {
			if v.Health.OK {
				health = fmt.Sprintf("✅ %d 条", v.Health.Entries)
			} else {
				health = "❌ " + subFirstLine(v.Health.Err)
			}
		}
		b.WriteString(fmt.Sprintf("\n%s <b>%s</b> · %s · %s",
			status, html.EscapeString(v.Name), html.EscapeString(v.Category), html.EscapeString(health)))
	}
	b.WriteString("\n\n点条目查看详情 / 管理。")
	return b.String()
}

func renderSubDetail(v SubscriptionView) string {
	enabled := "启用"
	if !v.Enabled {
		enabled = "停用"
	}
	var b strings.Builder
	b.WriteString(fmt.Sprintf("<b>📚 %s</b>\n", html.EscapeString(v.Name)))
	b.WriteString(fmt.Sprintf("\nID：<code>%s</code>", html.EscapeString(v.ID)))
	b.WriteString(fmt.Sprintf("\n分类：%s · 格式：%s", html.EscapeString(v.Category), html.EscapeString(v.Format)))
	b.WriteString(fmt.Sprintf("\n状态：%s · 周期：%s", enabled, html.EscapeString(v.Interval.String())))
	b.WriteString(fmt.Sprintf("\nURL：<code>%s</code>", html.EscapeString(v.URL)))
	if v.Health != nil {
		res := "✅ 成功"
		if !v.Health.OK {
			res = "❌ 失败"
		}
		b.WriteString(fmt.Sprintf("\n\n最近抓取：%s（%s）· %d 条",
			res, html.EscapeString(v.Health.At), v.Health.Entries))
		if v.Health.Err != "" {
			b.WriteString(fmt.Sprintf("\n错误：%s", html.EscapeString(subFirstLine(v.Health.Err))))
		}
	} else {
		b.WriteString("\n\n（尚未抓取）")
	}
	return b.String()
}

// --------------------------------------------------------------------------- //
// Controller-backed operations
// --------------------------------------------------------------------------- //

func (bt *Bot) findSubView(id string) (SubscriptionView, bool) {
	for _, v := range bt.ctrl.SubscriptionsWithHealth() {
		if v.ID == id {
			return v, true
		}
	}
	return SubscriptionView{}, false
}

func (bt *Bot) doSubsList() (string, *models.InlineKeyboardMarkup) {
	views := bt.ctrl.SubscriptionsWithHealth()
	return renderSubsList(views), subsMenu(views)
}

func (bt *Bot) doSubDetail(id string) (string, *models.InlineKeyboardMarkup) {
	v, ok := bt.findSubView(id)
	if !ok {
		return "订阅不存在（可能已删除）。", backKB("menu:subs")
	}
	return renderSubDetail(v), subDetailKB(v)
}

func (bt *Bot) doSubRefresh(ctx context.Context, id string) (string, *models.InlineKeyboardMarkup) {
	res := bt.ctrl.Update(ctx, id)
	v, ok := bt.findSubView(id)
	if !ok {
		return renderUpdateResults(res), backKB("menu:subs")
	}
	return renderUpdateResults(res) + "\n\n" + renderSubDetail(v), subDetailKB(v)
}

// doSubToggle flips Enabled. There is no atomic Controller toggle, so it mirrors
// the API's validate/remove/add dance (api.go handleSubscriptionsReplace),
// restoring the original on failure.
func (bt *Bot) doSubToggle(id string) (string, *models.InlineKeyboardMarkup) {
	sub, ok := bt.ctrl.GetSubscription(id)
	if !ok {
		return "订阅不存在。", backKB("menu:subs")
	}
	sub.Enabled = !sub.Enabled
	if err := bt.ctrl.RemoveSubscription(id); err != nil {
		return "切换失败：" + html.EscapeString(err.Error()), backKB("menu:subs")
	}
	if _, err := bt.ctrl.AddSubscription(sub); err != nil {
		sub.Enabled = !sub.Enabled // restore original
		_, _ = bt.ctrl.AddSubscription(sub)
		return "切换失败（已回滚）：" + html.EscapeString(err.Error()), backKB("menu:subs")
	}
	return bt.doSubDetail(id)
}

func (bt *Bot) doSubDelete(id string) (string, *models.InlineKeyboardMarkup) {
	if err := bt.ctrl.RemoveSubscription(id); err != nil {
		return "删除失败：" + html.EscapeString(err.Error()), backKB("menu:subs")
	}
	return bt.doSubsList()
}

// --------------------------------------------------------------------------- //
// Add wizard: category (button) → format (button) → name (text) → url (text)
// --------------------------------------------------------------------------- //

func (bt *Bot) startSubAdd(chatID int64) (string, *models.InlineKeyboardMarkup) {
	bt.clearPending(chatID)
	bt.setSubDraft(chatID, &subDraft{})
	return "➕ 新增订阅（1/4）：选择<b>分类</b>", categoryPickerKB()
}

func (bt *Bot) subSetCategory(chatID int64, cat string) (string, *models.InlineKeyboardMarkup) {
	d := bt.getSubDraft(chatID)
	if d == nil {
		return "会话已过期，请重新开始。", backKB("menu:subs")
	}
	d.category = cat
	return "➕ 新增订阅（2/4）：选择<b>格式</b>", formatPickerKB()
}

func (bt *Bot) subSetFormat(chatID int64, format string) string {
	d := bt.getSubDraft(chatID)
	if d == nil {
		return "会话已过期，请重新开始。"
	}
	d.format = format
	bt.setPending(chatID, "sub_name")
	return "➕ 新增订阅（3/4）：发送订阅<b>名称</b>（也用作 ID，如 <code>easylist-cn</code>）。发送 /cancel 取消。"
}

// subSetName consumes the pending name text and asks for the URL.
func (bt *Bot) subSetName(chatID int64, name string) string {
	d := bt.getSubDraft(chatID)
	if d == nil {
		return "会话已过期，请重新开始。"
	}
	d.name = strings.TrimSpace(name)
	bt.setPending(chatID, "sub_url")
	return "➕ 新增订阅（4/4）：发送订阅 <b>URL</b>。发送 /cancel 取消。"
}

// subFinish consumes the pending URL text, builds and validates the
// subscription, adds it, and returns the new detail view.
func (bt *Bot) subFinish(chatID int64, url string) (string, *models.InlineKeyboardMarkup) {
	d := bt.getSubDraft(chatID)
	bt.clearSubDraft(chatID)
	if d == nil {
		return "会话已过期，请重新开始。", backKB("menu:subs")
	}
	sub := Subscription{
		ID:       d.name,
		Category: d.category,
		Name:     d.name,
		URL:      strings.TrimSpace(url),
		Format:   d.format,
		Enabled:  true,
		Interval: 24 * time.Hour,
	}
	if err := bt.ctrl.ValidateSubscription(sub); err != nil {
		return "❌ 校验失败：" + html.EscapeString(err.Error()), backKB("menu:subs")
	}
	if _, err := bt.ctrl.AddSubscription(sub); err != nil {
		return "❌ 添加失败：" + html.EscapeString(err.Error()), backKB("menu:subs")
	}
	return bt.doSubDetail(sub.ID)
}
