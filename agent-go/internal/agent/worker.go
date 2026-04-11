package agent

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"time"
)

type CommandExecutor interface {
	Execute(request JobRequest) ExecutionResult
}

type Worker struct {
	AgentName string
	Client    ControlPlane
	Executor  CommandExecutor
	Now       func() time.Time
}

func (w Worker) RunOnce() (*JobResult, bool, error) {
	request, err := w.Client.ClaimNext(w.AgentName)
	if err != nil {
		return nil, false, err
	}
	if request == nil {
		return nil, true, nil
	}

	now := w.now()
	startedAt := now.Format(time.RFC3339)
	execution := w.executor().Execute(*request)
	finishedAt := w.now().Format(time.RFC3339)
	logUpload, err := w.upload("combined-log", safeID(request.JobID+"-combined-log"), "diagnostic", "text/plain", execution.CombinedLog)
	if err != nil {
		return nil, false, err
	}
	artifactUploads, err := w.uploadArtifacts(*request)
	if err != nil {
		return nil, false, err
	}

	result := JobResult{
		JobID:           request.JobID,
		Status:          execution.Status,
		ExitCode:        execution.ExitCode,
		StartedAt:       startedAt,
		FinishedAt:      finishedAt,
		Summary:         fmt.Sprintf("%s %v %s", request.Command, request.Args, execution.Status),
		LogUploads:      []ArtifactUpload{logUpload},
		ArtifactUploads: artifactUploads,
		WorkspaceDescriptor: WorkspaceDescriptor{
			WorkspaceKind:    request.SourceDescriptor.WorkspaceKind,
			RuntimeProfile:   request.RuntimeProfile,
			WorkspaceID:      safeID(request.RuntimeProfile + "-" + request.JobID),
			SourceDescriptor: request.SourceDescriptor,
			SlotDescriptors: map[string]map[string]any{
				"primary": {
					"runtime_path": absPath(request.WorkingDir),
					"dirty":        nil,
				},
			},
		},
		Heartbeat: finishedAt,
	}
	return &result, false, w.Client.SubmitResult(result)
}

func (w Worker) uploadArtifacts(request JobRequest) ([]ArtifactUpload, error) {
	var uploads []ArtifactUpload
	for _, rule := range request.ArtifactRules {
		role := rule["role"]
		retentionClass := rule["retention_class"]
		if retentionClass == "" {
			retentionClass = "evidence"
		}
		paths, err := filepath.Glob(filepath.Join(request.WorkingDir, rule["glob"]))
		if err != nil {
			return nil, err
		}
		sort.Strings(paths)
		for _, path := range paths {
			content, err := os.ReadFile(path)
			if err != nil {
				return nil, err
			}
			id := safeID(fmt.Sprintf("%s-%s-%s", request.JobID, role, filepath.Base(path)))
			upload, err := w.upload(role, id, retentionClass, rule["media_type"], content)
			if err != nil {
				return nil, err
			}
			uploads = append(uploads, upload)
		}
	}
	return uploads, nil
}

func (w Worker) upload(role, artifactID, retentionClass, mediaType string, content []byte) (ArtifactUpload, error) {
	sum := sha256.Sum256(content)
	upload := ArtifactUpload{
		ArtifactID:     artifactID,
		Role:           role,
		Digest:         "sha256:" + hex.EncodeToString(sum[:]),
		ByteSize:       len(content),
		RetentionClass: retentionClass,
		MediaType:      mediaType,
	}
	return w.Client.UploadArtifact(upload, content)
}

func (w Worker) executor() CommandExecutor {
	if w.Executor != nil {
		return w.Executor
	}
	return Executor{}
}

func (w Worker) now() time.Time {
	if w.Now != nil {
		return w.Now()
	}
	return time.Now().UTC()
}

func absPath(path string) string {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return path
	}
	return absolute
}

var unsafeIDPattern = regexp.MustCompile(`[^A-Za-z0-9._:-]`)

func safeID(value string) string {
	return unsafeIDPattern.ReplaceAllString(value, "-")
}
