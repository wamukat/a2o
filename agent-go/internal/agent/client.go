package agent

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
)

type ControlPlane interface {
	ClaimNext(agentName string) (*JobRequest, error)
	UploadArtifact(upload ArtifactUpload, content []byte) (ArtifactUpload, error)
	SubmitResult(result JobResult) error
}

type HTTPClient struct {
	BaseURL       string
	Token         string
	TokenFile     string
	FallbackToken string
	HTTPClient    *http.Client
}

func (c HTTPClient) ClaimNext(agentName string) (*JobRequest, error) {
	u, err := url.Parse(c.BaseURL)
	if err != nil {
		return nil, err
	}
	u.Path = "/v1/agent/jobs/next"
	u.RawQuery = url.Values{"agent": []string{agentName}}.Encode()
	req, err := http.NewRequest(http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, err
	}
	if err := c.authorize(req); err != nil {
		return nil, err
	}
	resp, err := c.client().Do(req)
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
	u, err := url.Parse(c.BaseURL)
	if err != nil {
		return ArtifactUpload{}, err
	}
	u.Path = "/v1/agent/artifacts/" + url.PathEscape(upload.ArtifactID)
	query := url.Values{
		"role":            []string{upload.Role},
		"digest":          []string{upload.Digest},
		"byte_size":       []string{strconv.Itoa(upload.ByteSize)},
		"retention_class": []string{upload.RetentionClass},
	}
	if upload.MediaType != "" {
		query.Set("media_type", upload.MediaType)
	}
	u.RawQuery = query.Encode()
	req, err := http.NewRequest(http.MethodPut, u.String(), bytes.NewReader(content))
	if err != nil {
		return ArtifactUpload{}, err
	}
	if err := c.authorize(req); err != nil {
		return ArtifactUpload{}, err
	}
	resp, err := c.client().Do(req)
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

func (c HTTPClient) SubmitResult(result JobResult) error {
	u, err := url.Parse(c.BaseURL)
	if err != nil {
		return err
	}
	u.Path = "/v1/agent/jobs/" + url.PathEscape(result.JobID) + "/result"
	payload, err := json.Marshal(result)
	if err != nil {
		return err
	}
	req, err := http.NewRequest(http.MethodPost, u.String(), bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("content-type", "application/json")
	if err := c.authorize(req); err != nil {
		return err
	}
	resp, err := c.client().Do(req)
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
	return http.DefaultClient
}

func responseError(operation string, resp *http.Response) error {
	_, _ = io.Copy(io.Discard, resp.Body)
	return fmt.Errorf("%s failed: HTTP %d", operation, resp.StatusCode)
}
