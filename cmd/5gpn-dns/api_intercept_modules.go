package main

import (
	"errors"
	"net/http"
)

func (s *ControlServer) SetInterceptModuleManager(manager *InterceptModuleManager) {
	s.interceptModules = manager
	if manager != nil && manager.store != nil {
		s.interceptStore = manager.store
	}
}

func (s *ControlServer) handleInterceptModulesGet(w http.ResponseWriter, _ *http.Request) {
	if s.interceptModules == nil {
		writeErr(w, http.StatusServiceUnavailable, errInterceptModulesUnavailable.Error())
		return
	}
	view, err := s.interceptModules.View()
	if err != nil {
		writeInterceptModuleError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, view)
}

func (s *ControlServer) handleInterceptModulesReorder(w http.ResponseWriter, r *http.Request) {
	if s.interceptModules == nil {
		writeErr(w, http.StatusServiceUnavailable, errInterceptModulesUnavailable.Error())
		return
	}
	var request struct {
		Revision       string   `json:"revision"`
		ExecutionOrder []string `json:"execution_order"`
	}
	if !decodeJSONBody(w, r, &request) {
		return
	}
	view, err := s.interceptModules.Reorder(r.Context(), request.Revision, request.ExecutionOrder)
	if err != nil {
		writeInterceptModuleError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, view)
}

func (s *ControlServer) handleInterceptModuleSnapshotGet(w http.ResponseWriter, r *http.Request) {
	if s.interceptModules == nil {
		writeErr(w, http.StatusServiceUnavailable, errInterceptModulesUnavailable.Error())
		return
	}
	view, err := s.interceptModules.Snapshot(r.PathValue("id"))
	if err != nil {
		writeInterceptModuleError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, view)
}

func (s *ControlServer) handleInterceptModulesImport(w http.ResponseWriter, r *http.Request) {
	if s.interceptModules == nil {
		writeErr(w, http.StatusServiceUnavailable, errInterceptModulesUnavailable.Error())
		return
	}
	var request interceptModuleImportRequest
	if !decodeJSONBodyLimit(w, r, &request, 16<<20) {
		return
	}
	view, err := s.interceptModules.Import(r.Context(), request)
	if err != nil {
		writeInterceptModuleError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, view)
}

func (s *ControlServer) handleInterceptModuleUpdateCheck(w http.ResponseWriter, r *http.Request) {
	if s.interceptModules == nil {
		writeErr(w, http.StatusServiceUnavailable, errInterceptModulesUnavailable.Error())
		return
	}
	var request struct {
		Revision string `json:"revision"`
	}
	if !decodeJSONBody(w, r, &request) {
		return
	}
	view, err := s.interceptModules.CheckUpdate(r.Context(), r.PathValue("id"), request.Revision)
	if err != nil {
		writeInterceptModuleError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, view)
}

func (s *ControlServer) handleInterceptModuleUpdateApply(w http.ResponseWriter, r *http.Request) {
	if s.interceptModules == nil {
		writeErr(w, http.StatusServiceUnavailable, errInterceptModulesUnavailable.Error())
		return
	}
	var request struct {
		Revision       string `json:"revision"`
		SnapshotDigest string `json:"snapshot_digest"`
	}
	if !decodeJSONBody(w, r, &request) {
		return
	}
	view, err := s.interceptModules.ApplyUpdate(r.Context(), r.PathValue("id"), request.Revision, request.SnapshotDigest)
	if err != nil {
		writeInterceptModuleError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, view)
}

func (s *ControlServer) handleInterceptModulePut(w http.ResponseWriter, r *http.Request) {
	if s.interceptModules == nil {
		writeErr(w, http.StatusServiceUnavailable, errInterceptModulesUnavailable.Error())
		return
	}
	var update interceptModuleUpdate
	if !decodeJSONBody(w, r, &update) {
		return
	}
	view, err := s.interceptModules.Update(r.Context(), r.PathValue("id"), update)
	if err != nil {
		writeInterceptModuleError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, view)
}

func (s *ControlServer) handleInterceptModuleDelete(w http.ResponseWriter, r *http.Request) {
	if s.interceptModules == nil {
		writeErr(w, http.StatusServiceUnavailable, errInterceptModulesUnavailable.Error())
		return
	}
	var request struct {
		Revision string `json:"revision"`
	}
	if !decodeJSONBody(w, r, &request) {
		return
	}
	view, err := s.interceptModules.Delete(r.Context(), r.PathValue("id"), request.Revision)
	if err != nil {
		writeInterceptModuleError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, view)
}

func writeInterceptModuleError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, errInterceptModulesUnavailable):
		writeErr(w, http.StatusServiceUnavailable, err.Error())
	case errors.Is(err, errInterceptRevisionConflict), errors.Is(err, errInterceptModuleConflict):
		writeErr(w, http.StatusConflict, err.Error())
	case errors.Is(err, errInterceptModuleNotFound):
		writeErr(w, http.StatusNotFound, err.Error())
	case errors.Is(err, errInterceptApplyFailed):
		writeErr(w, http.StatusBadGateway, err.Error())
	default:
		writeErr(w, http.StatusBadRequest, err.Error())
	}
}
