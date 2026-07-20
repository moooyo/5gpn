package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"math"
	"strconv"
	"strings"

	"github.com/go-telegram/bot/models"
)

const unknownBotExtensionLocationAccuracy uint32 = 100000

// parseBotExtensionSettingText converts an explicit Telegram text reply into
// the native JSON representation used by the extension manager. Clearing an
// optional setting is represented separately by a nil value.
func parseBotExtensionSettingText(setting interceptModuleSetting, input string) (json.RawMessage, error) {
	var raw json.RawMessage
	var err error

	switch setting.Type {
	case "text", "select":
		raw, err = json.Marshal(input)
	case "boolean", "number":
		trimmed := strings.TrimSpace(input)
		if trimmed == "" {
			return nil, errors.New("setting value must not be empty")
		}
		raw = json.RawMessage(trimmed)
	case "location":
		raw, err = parseBotExtensionLocationText(input)
	default:
		return nil, fmt.Errorf("unsupported setting type %q", setting.Type)
	}
	if err != nil {
		return nil, fmt.Errorf("parse setting %q: %w", setting.Key, err)
	}
	if err := validateInterceptSettingValue(setting, raw, true); err != nil {
		return nil, fmt.Errorf("invalid value for setting %q: %w", setting.Key, err)
	}
	return append(json.RawMessage(nil), raw...), nil
}

func parseBotExtensionLocationText(input string) (json.RawMessage, error) {
	parts := strings.Split(input, ",")
	if len(parts) != 3 {
		return nil, errors.New("location must use longitude,latitude,accuracy")
	}
	for index := range parts {
		parts[index] = strings.TrimSpace(parts[index])
		if parts[index] == "" {
			return nil, errors.New("location must use longitude,latitude,accuracy")
		}
	}

	longitude, err := strconv.ParseFloat(parts[0], 64)
	if err != nil {
		return nil, errors.New("longitude must be a number")
	}
	latitude, err := strconv.ParseFloat(parts[1], 64)
	if err != nil {
		return nil, errors.New("latitude must be a number")
	}
	accuracy, err := strconv.ParseUint(parts[2], 10, 32)
	if err != nil {
		return nil, errors.New("accuracy must be an integer")
	}

	value := interceptLocationValue{
		Longitude: &longitude,
		Latitude:  &latitude,
		Accuracy:  uint32(accuracy),
	}
	return json.Marshal(value)
}

// botExtensionLocationValue converts a Telegram location into the strict
// native extension representation. Accuracy is rounded up so the stored value
// never claims greater precision than Telegram supplied.
func botExtensionLocationValue(location models.Location) (json.RawMessage, error) {
	// Telegram omits HorizontalAccuracy when it is unknown. Use the widest
	// value accepted by the extension contract instead of inventing precision.
	accuracy := unknownBotExtensionLocationAccuracy
	if location.HorizontalAccuracy != 0 {
		rounded := math.Ceil(location.HorizontalAccuracy)
		if math.IsNaN(rounded) || math.IsInf(rounded, 0) || rounded < 1 || rounded > 100000 {
			return nil, errors.New("location accuracy must be between 1 and 100000")
		}
		accuracy = uint32(rounded)
	}

	longitude := location.Longitude
	latitude := location.Latitude
	value := interceptLocationValue{
		Longitude: &longitude,
		Latitude:  &latitude,
		Accuracy:  accuracy,
	}
	raw, err := json.Marshal(value)
	if err != nil {
		return nil, fmt.Errorf("encode Telegram location: %w", err)
	}
	setting := interceptModuleSetting{Type: "location"}
	if err := validateInterceptSettingValue(setting, raw, true); err != nil {
		return nil, fmt.Errorf("invalid Telegram location: %w", err)
	}
	return raw, nil
}

// buildBotExtensionSettings creates the complete settings map required by the
// extension manager while replacing exactly one setting. A nil or JSON null
// replacement clears an optional setting.
func buildBotExtensionSettings(settings []interceptModuleSetting, key string, value json.RawMessage) (map[string]json.RawMessage, error) {
	values := make(map[string]json.RawMessage, len(settings))
	found := false
	for index := range settings {
		setting := settings[index]
		if _, duplicate := values[setting.Key]; duplicate {
			return nil, fmt.Errorf("duplicate extension setting %q", setting.Key)
		}

		current := setting.Value
		if setting.Key == key {
			found = true
			current = value
			if len(current) == 0 || bytes.Equal(bytes.TrimSpace(current), []byte("null")) {
				current = nil
			}
			if err := validateInterceptSettingValue(setting, current, setting.Required); err != nil {
				return nil, fmt.Errorf("invalid value for setting %q: %w", setting.Key, err)
			}
		}
		values[setting.Key] = append(json.RawMessage(nil), current...)
	}
	if !found {
		return nil, fmt.Errorf("extension setting %q was not found", key)
	}
	return values, nil
}

// botExtensionSettingValueHTML renders the current value as Telegram-safe
// HTML. The returned string contains only locally-authored tags.
func botExtensionSettingValueHTML(setting interceptModuleSetting) string {
	return botExtensionSettingRawValueHTML(setting, setting.Value)
}

// botExtensionSettingConfirmationHTML summarizes a proposed setting change.
// Both manifest metadata and setting values are escaped before interpolation.
func botExtensionSettingConfirmationHTML(setting interceptModuleSetting, value json.RawMessage) string {
	label := setting.Label
	if strings.TrimSpace(label) == "" {
		label = setting.Key
	}
	return fmt.Sprintf(
		"⚠️ <b>确认修改插件参数？</b>\n参数：<code>%s</code>\n当前值：%s\n新值：%s",
		html.EscapeString(label),
		botExtensionSettingRawValueHTML(setting, setting.Value),
		botExtensionSettingRawValueHTML(setting, value),
	)
}

func botExtensionSettingRawValueHTML(setting interceptModuleSetting, raw json.RawMessage) string {
	if len(raw) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return "<i>未设置</i>"
	}
	if err := validateInterceptSettingValue(setting, raw, false); err != nil {
		return "<i>无效值</i>"
	}

	var rendered string
	switch setting.Type {
	case "text", "select":
		var value string
		if err := json.Unmarshal(raw, &value); err != nil {
			return "<i>无效值</i>"
		}
		rendered = value
	case "boolean", "number":
		rendered = string(bytes.TrimSpace(raw))
	case "location":
		var value interceptLocationValue
		if err := unmarshalStrictJSON(raw, &value); err != nil {
			return "<i>无效值</i>"
		}
		if value.Longitude == nil {
			rendered = fmt.Sprintf("accuracy=%d", value.Accuracy)
		} else {
			rendered = fmt.Sprintf(
				"%s,%s,%d",
				strconv.FormatFloat(*value.Longitude, 'g', -1, 64),
				strconv.FormatFloat(*value.Latitude, 'g', -1, 64),
				value.Accuracy,
			)
		}
	default:
		return "<i>无效值</i>"
	}
	return "<code>" + html.EscapeString(rendered) + "</code>"
}
