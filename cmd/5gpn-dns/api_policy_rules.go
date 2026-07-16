// Package main (this file): the /api/policy/* REST surface — the
// console-facing CRUD over the unified policy-rule model (policy_rules.go's
// PolicyRuleManager) plus the apply verb that drives the compile+DNS
// pipeline (policy_engine.go's PolicyEngine.CompileAndApply). Handler idiom:
// decodeJSONBody → call the Controller facade → map errors via
// policyRuleErrStatus → writeJSON.
//
// The handlers expose the unified rule list that drives the live resolver;
// see policy_rules.go and policy_engine.go for the store/compiler boundary.
package main

import (
	"errors"
	"net/http"
)

// policyRuleErrStatus maps a policy-rule-model/manager error to an HTTP
// status: an unwired PolicyRuleManager/PolicyEngine (ErrPolicyRulesUnavailable)
// is 503, a missing rule ID (ErrPolicyNotFound) is 404, a validation failure
// (ErrInvalidPolicy: a bad enum value, an empty required field, or an
// injection-unsafe matcher value) is 400, and anything else (e.g. a disk
// write failure while persisting an otherwise-valid entry, or an apply-time
// compile rejection — CompileAndApply's errors aren't wrapped in
// ErrInvalidPolicy) is 500.
func policyRuleErrStatus(err error) int {
	switch {
	case errors.Is(err, ErrPolicyRulesUnavailable):
		return http.StatusServiceUnavailable
	case errors.Is(err, ErrPolicyNotFound):
		return http.StatusNotFound
	case errors.Is(err, ErrInvalidPolicy):
		return http.StatusBadRequest
	default:
		return http.StatusInternalServerError
	}
}

// ---------------------------------------------------------------------------
// Rule CRUD: GET/POST /api/policy/rules, PATCH/DELETE .../{id}
// ---------------------------------------------------------------------------

// nonNilList guarantees a GET-list handler always answers with a JSON array,
// never the literal null a nil slice encodes as.
func nonNilList[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

// handlePolicyRulesList returns every policy rule in evaluation order. Empty
// (never null) whether no PolicyRuleManager is wired or the list is simply
// empty (PolicyRuleManager.Rules already returns a non-nil slice, but
// nonNilList is applied for future-proof uniformity).
func (s *ControlServer) handlePolicyRulesList(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, nonNilList(s.ctrl.PolicyRules()))
}

// handlePolicyRulesCreate decodes a PolicyRule from the body and adds it.
// AddPolicyRule (via PolicyRuleManager.AddRule) always mints a fresh ID
// itself — any client-supplied id is ignored.
func (s *ControlServer) handlePolicyRulesCreate(w http.ResponseWriter, r *http.Request) {
	var pr PolicyRule
	if !decodeJSONBody(w, r, &pr) {
		return
	}
	created, err := s.ctrl.AddPolicyRule(pr)
	if err != nil {
		writeErr(w, policyRuleErrStatus(err), err.Error())
		return
	}
	writeJSON(w, http.StatusOK, created)
}

// handlePolicyRulesReplace decodes a PolicyRule from the body, forces its ID
// to the path value (the URL is authoritative, matching the subscription
// PATCH convention), and replaces the existing entry.
func (s *ControlServer) handlePolicyRulesReplace(w http.ResponseWriter, r *http.Request) {
	var pr PolicyRule
	if !decodeJSONBody(w, r, &pr) {
		return
	}
	updated, err := s.ctrl.UpdatePolicyRule(r.PathValue("id"), pr)
	if err != nil {
		writeErr(w, policyRuleErrStatus(err), err.Error())
		return
	}
	writeJSON(w, http.StatusOK, updated)
}

// handlePolicyRulesDelete removes a policy rule by path ID.
func (s *ControlServer) handlePolicyRulesDelete(w http.ResponseWriter, r *http.Request) {
	if err := s.ctrl.DeletePolicyRule(r.PathValue("id")); err != nil {
		writeErr(w, policyRuleErrStatus(err), err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// ---------------------------------------------------------------------------
// Reorder
// ---------------------------------------------------------------------------

// policyReorderRequest is the wire shape of PUT /api/policy/rules/reorder.
type policyReorderRequest struct {
	IDs []string `json:"ids"`
}

// handlePolicyRulesReorder decodes {"ids":[...]} and rewrites the evaluation
// order to match it exactly (ReorderPolicyRules/PolicyRuleManager.Reorder
// rejects a partial/mismatched id set as ErrInvalidPolicy, mapped to 400).
func (s *ControlServer) handlePolicyRulesReorder(w http.ResponseWriter, r *http.Request) {
	var body policyReorderRequest
	if !decodeJSONBody(w, r, &body) {
		return
	}
	if err := s.ctrl.ReorderPolicyRules(body.IDs); err != nil {
		writeErr(w, policyRuleErrStatus(err), err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// ---------------------------------------------------------------------------
// Fallback
// ---------------------------------------------------------------------------

// handlePolicyFallbackGet returns the current fallback policy + default
// selector.
func (s *ControlServer) handlePolicyFallbackGet(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.ctrl.GetPolicyFallback())
}

// handlePolicyFallbackSet decodes a Fallback from the body and applies it.
func (s *ControlServer) handlePolicyFallbackSet(w http.ResponseWriter, r *http.Request) {
	var f Fallback
	if !decodeJSONBody(w, r, &f) {
		return
	}
	if err := s.ctrl.SetPolicyFallback(f); err != nil {
		writeErr(w, policyRuleErrStatus(err), err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// ---------------------------------------------------------------------------
// Apply
// ---------------------------------------------------------------------------

// handlePolicyApply runs PolicyEngine.CompileAndApply: compile the current
// PolicyModel, validate + apply the mihomo side (`mihomo -t`, Global
// Constraints R4), and — only on that success — commit the DNS side (manual
// rule files, subscription fetch/provider sync, the fallback switch, a rule
// reload). See Controller.ApplyPolicy / PolicyEngine.CompileAndApply for the
// full pipeline.
func (s *ControlServer) handlePolicyApply(w http.ResponseWriter, r *http.Request) {
	if err := s.ctrl.ApplyPolicy(r.Context()); err != nil {
		writeErr(w, policyRuleErrStatus(err), err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}
