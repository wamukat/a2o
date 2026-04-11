package agent

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestHTTPClientUsesAgentProtocol(t *testing.T) {
	var uploaded bool
	var submitted bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/v1/agent/jobs/next":
			if r.URL.Query().Get("agent") != "host-local" {
				t.Fatalf("agent query = %q", r.URL.Query().Get("agent"))
			}
			writeJSON(w, http.StatusOK, map[string]any{"job": testRequest(t.TempDir())})
		case r.Method == http.MethodPut && r.URL.Path == "/v1/agent/artifacts/art-log-1":
			uploaded = true
			writeJSON(w, http.StatusCreated, map[string]any{"artifact": ArtifactUpload{
				ArtifactID:     "art-log-1",
				Role:           "combined-log",
				Digest:         r.URL.Query().Get("digest"),
				ByteSize:       3,
				RetentionClass: "diagnostic",
			}})
		case r.Method == http.MethodPost && r.URL.Path == "/v1/agent/jobs/job-1/result":
			submitted = true
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"job":{}}`))
		default:
			t.Fatalf("unexpected request: %s %s", r.Method, r.URL.String())
		}
	}))
	defer server.Close()

	client := HTTPClient{BaseURL: server.URL}
	job, err := client.ClaimNext("host-local")
	if err != nil {
		t.Fatal(err)
	}
	if job.JobID != "job-1" {
		t.Fatalf("job id = %s", job.JobID)
	}
	_, err = client.UploadArtifact(ArtifactUpload{
		ArtifactID:     "art-log-1",
		Role:           "combined-log",
		Digest:         "sha256:abc",
		ByteSize:       3,
		RetentionClass: "diagnostic",
	}, []byte("log"))
	if err != nil {
		t.Fatal(err)
	}
	if err := client.SubmitResult(JobResult{JobID: "job-1"}); err != nil {
		t.Fatal(err)
	}
	if !uploaded || !submitted {
		t.Fatalf("uploaded=%v submitted=%v", uploaded, submitted)
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
	if err := client.SubmitResult(JobResult{JobID: "job-1"}); err != nil {
		t.Fatal(err)
	}
	if authorizedRequests != 3 {
		t.Fatalf("authorized requests = %d, want 3", authorizedRequests)
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

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("content-type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}
