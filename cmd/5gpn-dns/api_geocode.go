package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
)

const defaultGeocodeEndpoint = "https://nominatim.openstreetmap.org/search"

var geocodeLanguagePattern = regexp.MustCompile(`^[A-Za-z0-9,-]{1,64}$`)

type geocodeUpstreamResult struct {
	PlaceID     int64  `json:"place_id"`
	DisplayName string `json:"display_name"`
	Latitude    string `json:"lat"`
	Longitude   string `json:"lon"`
}

type geocodeCityResult struct {
	PlaceID     int64  `json:"place_id"`
	DisplayName string `json:"display_name"`
	Latitude    string `json:"lat"`
	Longitude   string `json:"lon"`
}

func newGeocodeHTTPClient(resolver HostResolver) *http.Client {
	client := newSubHTTPClient(resolver)
	client.Timeout = 12 * time.Second
	client.CheckRedirect = func(request *http.Request, via []*http.Request) error {
		if len(via) >= 2 {
			return errors.New("geocoder: too many redirects")
		}
		if request.URL.Scheme != "https" || !strings.EqualFold(request.URL.Hostname(), "nominatim.openstreetmap.org") {
			return errors.New("geocoder: redirect left the fixed Nominatim origin")
		}
		return nil
	}
	return client
}

func (s *ControlServer) SetGeocodeResolver(resolver HostResolver) {
	if s != nil {
		s.geocodeHTTP = newGeocodeHTTPClient(resolver)
		s.geocodeEndpoint = defaultGeocodeEndpoint
	}
}

func (s *ControlServer) handleGeocodeCities(w http.ResponseWriter, request *http.Request) {
	query := strings.TrimSpace(request.URL.Query().Get("q"))
	if query == "" || len(query) > 160 || containsControlRune(query) {
		writeErr(w, http.StatusBadRequest, "q must contain 1 to 160 bytes without control characters")
		return
	}
	language := strings.TrimSpace(request.URL.Query().Get("lang"))
	if language == "" {
		language = "en"
	}
	if !geocodeLanguagePattern.MatchString(language) {
		writeErr(w, http.StatusBadRequest, "lang is invalid")
		return
	}
	endpoint := s.geocodeEndpoint
	if endpoint == "" {
		endpoint = defaultGeocodeEndpoint
	}
	parsed, err := url.Parse(endpoint)
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "city search is unavailable")
		return
	}
	values := parsed.Query()
	values.Set("q", query)
	values.Set("format", "jsonv2")
	values.Set("limit", "6")
	values.Set("layer", "address")
	values.Set("accept-language", language)
	parsed.RawQuery = values.Encode()

	ctx, cancel := context.WithTimeout(request.Context(), 12*time.Second)
	defer cancel()
	upstreamRequest, err := http.NewRequestWithContext(ctx, http.MethodGet, parsed.String(), nil)
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "city search is unavailable")
		return
	}
	upstreamRequest.Header.Set("Accept", "application/json")
	upstreamRequest.Header.Set("Accept-Language", language)
	upstreamRequest.Header.Set("User-Agent", "5gpn-console-geocoder/1 (+https://github.com/moooyo/5gpn)")
	client := s.geocodeHTTP
	if client == nil {
		client = newGeocodeHTTPClient(nil)
	}
	response, err := client.Do(upstreamRequest)
	if err != nil {
		writeErr(w, http.StatusBadGateway, "city search upstream is unavailable")
		return
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		writeErr(w, http.StatusBadGateway, "city search upstream rejected the request")
		return
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, (128<<10)+1))
	if err != nil || len(body) > 128<<10 {
		writeErr(w, http.StatusBadGateway, "city search upstream response is invalid")
		return
	}
	var upstream []geocodeUpstreamResult
	if err := json.Unmarshal(body, &upstream); err != nil {
		writeErr(w, http.StatusBadGateway, "city search upstream response is invalid")
		return
	}
	results := make([]geocodeCityResult, 0, min(len(upstream), 6))
	for _, item := range upstream {
		if len(results) >= 6 || item.PlaceID <= 0 || item.DisplayName == "" || len(item.DisplayName) > 512 || containsControlRune(item.DisplayName) {
			continue
		}
		latitude, latErr := strconv.ParseFloat(item.Latitude, 64)
		longitude, lonErr := strconv.ParseFloat(item.Longitude, 64)
		if latErr != nil || lonErr != nil || math.IsNaN(latitude) || math.IsNaN(longitude) || math.IsInf(latitude, 0) || math.IsInf(longitude, 0) || latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180 {
			continue
		}
		results = append(results, geocodeCityResult{
			PlaceID: item.PlaceID, DisplayName: item.DisplayName,
			Latitude:  strconv.FormatFloat(latitude, 'f', -1, 64),
			Longitude: strconv.FormatFloat(longitude, 'f', -1, 64),
		})
	}
	writeJSON(w, http.StatusOK, results)
}

func containsControlRune(value string) bool {
	return strings.IndexFunc(value, unicode.IsControl) >= 0
}
