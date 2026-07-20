package main

import (
	"errors"
	"net/http"
)

func (s *ControlServer) SetExtensionMarketplaceManager(manager *ExtensionMarketplaceManager) {
	s.marketplaces = manager
}

func (s *ControlServer) handleMarketplacesGet(w http.ResponseWriter, _ *http.Request) {
	if s.marketplaces == nil {
		writeErr(w, http.StatusServiceUnavailable, errMarketplaceUnavailable.Error())
		return
	}
	view, err := s.marketplaces.View()
	if err != nil {
		writeMarketplaceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, view)
}

func (s *ControlServer) handleMarketplaceAdd(w http.ResponseWriter, r *http.Request) {
	if s.marketplaces == nil {
		writeErr(w, http.StatusServiceUnavailable, errMarketplaceUnavailable.Error())
		return
	}
	var request struct {
		Revision string `json:"revision"`
		URL      string `json:"url"`
		Name     string `json:"name"`
	}
	if !decodeJSONBody(w, r, &request) {
		return
	}
	view, err := s.marketplaces.Add(r.Context(), request.Revision, request.URL, request.Name)
	if err != nil {
		writeMarketplaceError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, view)
}

func (s *ControlServer) handleMarketplaceRefresh(w http.ResponseWriter, r *http.Request) {
	if s.marketplaces == nil {
		writeErr(w, http.StatusServiceUnavailable, errMarketplaceUnavailable.Error())
		return
	}
	var request struct {
		Revision string `json:"revision"`
	}
	if !decodeJSONBody(w, r, &request) {
		return
	}
	view, err := s.marketplaces.Refresh(r.Context(), r.PathValue("id"), request.Revision)
	if err != nil {
		writeMarketplaceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, view)
}

func (s *ControlServer) handleMarketplaceDelete(w http.ResponseWriter, r *http.Request) {
	if s.marketplaces == nil {
		writeErr(w, http.StatusServiceUnavailable, errMarketplaceUnavailable.Error())
		return
	}
	var request struct {
		Revision string `json:"revision"`
	}
	if !decodeJSONBody(w, r, &request) {
		return
	}
	view, err := s.marketplaces.Delete(r.Context(), r.PathValue("id"), request.Revision)
	if err != nil {
		writeMarketplaceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, view)
}

func (s *ControlServer) handleMarketplaceInstall(w http.ResponseWriter, r *http.Request) {
	if s.marketplaces == nil {
		writeErr(w, http.StatusServiceUnavailable, errMarketplaceUnavailable.Error())
		return
	}
	var request struct {
		MarketplaceRevision string `json:"marketplace_revision"`
		ModuleRevision      string `json:"module_revision"`
	}
	if !decodeJSONBody(w, r, &request) {
		return
	}
	view, err := s.marketplaces.Install(
		r.Context(), r.PathValue("marketplace"), r.PathValue("extension"),
		request.MarketplaceRevision, request.ModuleRevision,
	)
	if err != nil {
		writeMarketplaceError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, view)
}

func writeMarketplaceError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, errMarketplaceUnavailable), errors.Is(err, errInterceptModulesUnavailable):
		writeErr(w, http.StatusServiceUnavailable, err.Error())
	case errors.Is(err, errMarketplaceRevision), errors.Is(err, errMarketplaceConflict), errors.Is(err, errMarketplaceIntegrity),
		errors.Is(err, errInterceptRevisionConflict), errors.Is(err, errInterceptModuleConflict):
		writeErr(w, http.StatusConflict, err.Error())
	case errors.Is(err, errMarketplaceNotFound), errors.Is(err, errInterceptModuleNotFound):
		writeErr(w, http.StatusNotFound, err.Error())
	case errors.Is(err, errMarketplaceFetch), errors.Is(err, errInterceptApplyFailed):
		writeErr(w, http.StatusBadGateway, err.Error())
	default:
		writeErr(w, http.StatusBadRequest, err.Error())
	}
}
