package agent

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

type ControlPlane interface {
	ClaimNext(agentName string) (*JobRequest, error)
	Heartbeat(jobID string, heartbeat string) error
	UploadArtifact(upload ArtifactUpload, content []byte) (ArtifactUpload, error)
	SubmitResult(result JobResult) error
}

type HTTPClient struct {
	BaseURL        string
	ProjectKey     string
	Token          string
	TokenFile      string
	FallbackToken  string
	HTTPClient     *http.Client
	RequestTimeout time.Duration
	ConnectTimeout time.Duration
	RetryCount     int
	RetryDelay     time.Duration
}

func (c HTTPClient) ClaimNext(agentName string) (*JobRequest, error) {
	query := url.Values{"agent": []string{agentName}}
	if strings.TrimSpace(c.ProjectKey) != "" {
		query.Set("project_key", strings.TrimSpace(c.ProjectKey))
	}
	resp, err := c.do(http.MethodGet, "/v1/agent/jobs/next", query, nil, "")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNoContent {
		return nil, nil
	}
	if resp.StatusCode != http.StatusOK {
		return nil, responseError("claim_next", resp)
	}
	var body struct {
		Job JobRequest `json:"job"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, err
	}
	return &body.Job, nil
}

func (c HTTPClient) UploadArtifact(upload ArtifactUpload, content []byte) (ArtifactUpload, error) {
	query := url.Values{
		"role":            []string{upload.Role},
		"digest":          []string{upload.Digest},
		"byte_size":       []string{strconv.Itoa(upload.ByteSize)},
		"retention_class": []string{upload.RetentionClass},
	}
	if upload.MediaType != "" {
		query.Set("media_type", upload.MediaType)
	}
	if strings.TrimSpace(upload.ProjectKey) != "" {
		query.Set("project_key", strings.TrimSpace(upload.ProjectKey))
	}
	resp, err := c.do(http.MethodPut, "/v1/agent/artifacts/"+url.PathEscape(upload.ArtifactID), query, content, "")
	if err != nil {
		return ArtifactUpload{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		return ArtifactUpload{}, responseError("upload_artifact", resp)
	}
	var body struct {
		Artifact ArtifactUpload `json:"artifact"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return ArtifactUpload{}, err
	}
	return body.Artifact, nil
}

func (c HTTPClient) Heartbeat(jobID string, heartbeat string) error {
	payload, err := json.Marshal(map[string]string{"heartbeat": heartbeat})
	if err != nil {
		return err
	}
	resp, err := c.do(http.MethodPost, "/v1/agent/jobs/"+url.PathEscape(jobID)+"/heartbeat", nil, payload, "application/json")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return responseError("heartbeat", resp)
	}
	return nil
}

func (c HTTPClient) SubmitResult(result JobResult) error {
	payload, err := json.Marshal(result)
	if err != nil {
		return err
	}
	resp, err := c.do(http.MethodPost, "/v1/agent/jobs/"+url.PathEscape(result.JobID)+"/result", nil, payload, "application/json")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return responseError("submit_result", resp)
	}
	return nil
}

func (c HTTPClient) authorize(req *http.Request) error {
	token, err := c.authToken()
	if err != nil {
		return err
	}
	if token != "" {
		req.Header.Set("authorization", "Bearer "+token)
	}
	return nil
}

func (c HTTPClient) authToken() (string, error) {
	if c.Token != "" {
		return c.Token, nil
	}
	if c.TokenFile != "" {
		content, err := os.ReadFile(c.TokenFile)
		if err != nil {
			return "", fmt.Errorf("read agent token file: %w", err)
		}
		token := strings.TrimSpace(string(content))
		if token == "" {
			return "", fmt.Errorf("agent token file is empty: %s", c.TokenFile)
		}
		return token, nil
	}
	return c.FallbackToken, nil
}

func (c HTTPClient) client() *http.Client {
	if c.HTTPClient != nil {
		return c.HTTPClient
	}
	if c.RequestTimeout <= 0 && c.ConnectTimeout <= 0 {
		return http.DefaultClient
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	if c.ConnectTimeout > 0 {
		dialer := &net.Dialer{Timeout: c.ConnectTimeout}
		transport.DialContext = dialer.DialContext
	}
	client := &http.Client{Transport: transport}
	if c.RequestTimeout > 0 {
		client.Timeout = c.RequestTimeout
	}
	return client
}

func (c HTTPClient) do(method string, path string, query url.Values, body []byte, contentType string) (*http.Response, error) {
	var lastErr error
	attempts := c.RetryCount + 1
	if attempts < 1 {
		attempts = 1
	}
	for attempt := 1; attempt <= attempts; attempt++ {
		req, err := c.newRequest(method, path, query, body, contentType)
		if err != nil {
			return nil, err
		}
		resp, err := c.client().Do(req)
		if err == nil {
			if !shouldRetryStatus(resp.StatusCode) || attempt == attempts {
				return resp, nil
			}
			lastErr = responseError(method+" "+path, resp)
			resp.Body.Close()
		} else {
			lastErr = err
			if attempt == attempts {
				return nil, err
			}
		}
		if c.RetryDelay > 0 {
			time.Sleep(c.RetryDelay)
		}
	}
	return nil, lastErr
}

func (c HTTPClient) newRequest(method string, path string, query url.Values, body []byte, contentType string) (*http.Request, error) {
	u, err := url.Parse(c.BaseURL)
	if err != nil {
		return nil, err
	}
	u.Path = path
	if len(query) > 0 {
		u.RawQuery = query.Encode()
	}
	req, err := http.NewRequest(method, u.String(), bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	if contentType != "" {
		req.Header.Set("content-type", contentType)
	}
	if err := c.authorize(req); err != nil {
		return nil, err
	}
	return req, nil
}

func shouldRetryStatus(statusCode int) bool {
	return statusCode == http.StatusTooManyRequests ||
		statusCode == http.StatusBadGateway ||
		statusCode == http.StatusServiceUnavailable ||
		statusCode == http.StatusGatewayTimeout
}

func responseError(operation string, resp *http.Response) error {
	_, _ = io.Copy(io.Discard, resp.Body)
	return fmt.Errorf("%s failed: HTTP %d", operation, resp.StatusCode)
}
