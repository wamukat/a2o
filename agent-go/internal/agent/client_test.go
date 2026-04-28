package agent

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestHTTPClientUsesAgentProtocol(t *testing.T) {
	var uploaded bool
	var heartbeated bool
	var submitted bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/v1/agent/jobs/next":
			if r.URL.Query().Get("agent") != "host-local" {
				t.Fatalf("agent query = %q", r.URL.Query().Get("agent"))
			}
			if r.URL.Query().Get("project_key") != "a2o" {
				t.Fatalf("project_key query = %q", r.URL.Query().Get("project_key"))
			}
			writeJSON(w, http.StatusOK, map[string]any{"job": testRequest(t.TempDir())})
		case r.Method == http.MethodPut && r.URL.Path == "/v1/agent/artifacts/art-log-1":
			uploaded = true
			if r.URL.Query().Get("project_key") != "a2o" {
				t.Fatalf("project_key query = %q", r.URL.Query().Get("project_key"))
			}
			writeJSON(w, http.StatusCreated, map[string]any{"artifact": ArtifactUpload{
				ArtifactID:     "art-log-1",
				ProjectKey:     r.URL.Query().Get("project_key"),
				Role:           "combined-log",
				Digest:         r.URL.Query().Get("digest"),
				ByteSize:       3,
				RetentionClass: "analysis",
			}})
		case r.Method == http.MethodPost && r.URL.Path == "/v1/agent/jobs/job-1/heartbeat":
			heartbeated = true
			var payload map[string]string
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Fatal(err)
			}
			if payload["heartbeat"] != "2026-04-11T08:00:00Z" {
				t.Fatalf("heartbeat payload = %#v", payload)
			}
			w.WriteHeader(http.StatusOK)
		case r.Method == http.MethodPost && r.URL.Path == "/v1/agent/jobs/job-1/result":
			submitted = true
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"job":{}}`))
		default:
			t.Fatalf("unexpected request: %s %s", r.Method, r.URL.String())
		}
	}))
	defer server.Close()

	client := HTTPClient{BaseURL: server.URL, ProjectKey: "a2o"}
	job, err := client.ClaimNext("host-local")
	if err != nil {
		t.Fatal(err)
	}
	if job.JobID != "job-1" {
		t.Fatalf("job id = %s", job.JobID)
	}
	_, err = client.UploadArtifact(ArtifactUpload{
		ArtifactID:     "art-log-1",
		ProjectKey:     "a2o",
		Role:           "combined-log",
		Digest:         "sha256:abc",
		ByteSize:       3,
		RetentionClass: "analysis",
	}, []byte("log"))
	if err != nil {
		t.Fatal(err)
	}
	if err := client.Heartbeat("job-1", "2026-04-11T08:00:00Z"); err != nil {
		t.Fatal(err)
	}
	if err := client.SubmitResult(JobResult{JobID: "job-1"}); err != nil {
		t.Fatal(err)
	}
	if !uploaded || !heartbeated || !submitted {
		t.Fatalf("uploaded=%v heartbeated=%v submitted=%v", uploaded, heartbeated, submitted)
	}
}

func TestHTTPClientSendsBearerToken(t *testing.T) {
	var authorizedRequests int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("authorization") != "Bearer secret-token" {
			t.Fatalf("authorization = %q", r.Header.Get("authorization"))
		}
		authorizedRequests++
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/v1/agent/jobs/next":
			w.WriteHeader(http.StatusNoContent)
		case r.Method == http.MethodPut && r.URL.Path == "/v1/agent/artifacts/art-log-1":
			writeJSON(w, http.StatusCreated, map[string]any{"artifact": ArtifactUpload{ArtifactID: "art-log-1"}})
		case r.Method == http.MethodPost && r.URL.Path == "/v1/agent/jobs/job-1/heartbeat":
			w.WriteHeader(http.StatusOK)
		case r.Method == http.MethodPost && r.URL.Path == "/v1/agent/jobs/job-1/result":
			w.WriteHeader(http.StatusOK)
		default:
			t.Fatalf("unexpected request: %s %s", r.Method, r.URL.String())
		}
	}))
	defer server.Close()

	client := HTTPClient{BaseURL: server.URL, Token: "secret-token"}
	if _, err := client.ClaimNext("host-local"); err != nil {
		t.Fatal(err)
	}
	if _, err := client.UploadArtifact(ArtifactUpload{ArtifactID: "art-log-1"}, nil); err != nil {
		t.Fatal(err)
	}
	if err := client.Heartbeat("job-1", "2026-04-11T08:00:00Z"); err != nil {
		t.Fatal(err)
	}
	if err := client.SubmitResult(JobResult{JobID: "job-1"}); err != nil {
		t.Fatal(err)
	}
	if authorizedRequests != 4 {
		t.Fatalf("authorized requests = %d, want 4", authorizedRequests)
	}
}

func TestHTTPClientReloadsBearerTokenFromFile(t *testing.T) {
	var expectedToken = "first-token"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("authorization") != "Bearer "+expectedToken {
			t.Fatalf("authorization = %q, want Bearer %s", r.Header.Get("authorization"), expectedToken)
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	tokenPath := filepath.Join(t.TempDir(), "agent-token")
	if err := os.WriteFile(tokenPath, []byte("first-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	client := HTTPClient{BaseURL: server.URL, TokenFile: tokenPath}
	if _, err := client.ClaimNext("host-local"); err != nil {
		t.Fatal(err)
	}

	expectedToken = "second-token"
	if err := os.WriteFile(tokenPath, []byte("second-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := client.ClaimNext("host-local"); err != nil {
		t.Fatal(err)
	}
}

func TestHTTPClientRedactsErrorResponseBody(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":"secret-token leaked"}`))
	}))
	defer server.Close()

	client := HTTPClient{BaseURL: server.URL}
	_, err := client.ClaimNext("host-local")
	if err == nil {
		t.Fatal("expected error")
	}
	if strings.Contains(err.Error(), "secret-token") || strings.Contains(err.Error(), "leaked") {
		t.Fatalf("error leaked response body: %s", err)
	}
	if !strings.Contains(err.Error(), "HTTP 401") {
		t.Fatalf("error = %s", err)
	}
}

func TestHTTPClientRetriesTransientTransportErrors(t *testing.T) {
	attempts := 0
	client := HTTPClient{
		BaseURL:    "http://example.test",
		RetryCount: 2,
		HTTPClient: &http.Client{
			Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
				attempts++
				if attempts < 3 {
					return nil, errors.New("dial tcp 127.0.0.1:7393: i/o timeout")
				}
				return &http.Response{
					StatusCode: http.StatusNoContent,
					Body:       http.NoBody,
					Header:     make(http.Header),
					Request:    req,
				}, nil
			}),
		},
	}
	if _, err := client.ClaimNext("host-local"); err != nil {
		t.Fatal(err)
	}
	if attempts != 3 {
		t.Fatalf("attempts=%d, want 3", attempts)
	}
}

func TestHTTPClientRetriesTransientHTTPStatus(t *testing.T) {
	attempts := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempts++
		if attempts < 3 {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	client := HTTPClient{BaseURL: server.URL, RetryCount: 2, RetryDelay: time.Millisecond}
	if _, err := client.ClaimNext("host-local"); err != nil {
		t.Fatal(err)
	}
	if attempts != 3 {
		t.Fatalf("attempts=%d, want 3", attempts)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (fn roundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) {
	return fn(req)
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("content-type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}
