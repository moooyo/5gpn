package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func TestGeocodeCitiesUsesFixedBoundedProjection(t *testing.T) {
	t.Parallel()
	var calls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		calls.Add(1)
		if request.URL.Query().Get("q") != "Shenzhen" || request.URL.Query().Get("limit") != "6" || request.URL.Query().Get("format") != "jsonv2" {
			t.Errorf("query = %s", request.URL.RawQuery)
		}
		if request.Header.Get("Authorization") != "" || !strings.HasPrefix(request.Header.Get("User-Agent"), "5gpn-console-geocoder/") {
			t.Errorf("upstream headers = %+v", request.Header)
		}
		_, _ = w.Write([]byte(`[
          {"place_id":1,"display_name":"Shenzhen, Guangdong, China","lat":"22.544577","lon":"113.94114"},
          {"place_id":2,"display_name":"invalid","lat":"999","lon":"0"}
        ]`))
	}))
	defer upstream.Close()
	server := &ControlServer{geocodeHTTP: upstream.Client(), geocodeEndpoint: upstream.URL}
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/api/geocode/cities?q=Shenzhen&lang=zh-CN", nil)
	request.Header.Set("Authorization", "Bearer must-not-be-forwarded")
	server.handleGeocodeCities(recorder, request)
	if recorder.Code != http.StatusOK || calls.Load() != 1 {
		t.Fatalf("status=%d calls=%d body=%s", recorder.Code, calls.Load(), recorder.Body.String())
	}
	results := decodeJSON[[]geocodeCityResult](t, recorder)
	if len(results) != 1 || results[0].Longitude != "113.94114" || results[0].Latitude != "22.544577" {
		t.Fatalf("results = %+v", results)
	}
}

func TestGeocodeCitiesRejectsInvalidInputWithoutUpstream(t *testing.T) {
	t.Parallel()
	var calls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { calls.Add(1) }))
	defer upstream.Close()
	server := &ControlServer{geocodeHTTP: upstream.Client(), geocodeEndpoint: upstream.URL}
	for _, target := range []string{"/api/geocode/cities", "/api/geocode/cities?q=ok&lang=bad%20value"} {
		recorder := httptest.NewRecorder()
		server.handleGeocodeCities(recorder, httptest.NewRequest(http.MethodGet, target, nil))
		if recorder.Code != http.StatusBadRequest {
			t.Fatalf("%s status=%d", target, recorder.Code)
		}
	}
	if calls.Load() != 0 {
		t.Fatalf("invalid input reached upstream %d time(s)", calls.Load())
	}
}
