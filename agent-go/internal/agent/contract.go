package agent

type SourceDescriptor struct {
	WorkspaceKind string `json:"workspace_kind"`
	SourceType    string `json:"source_type"`
	Ref           string `json:"ref"`
	TaskRef       string `json:"task_ref"`
}

type JobRequest struct {
	JobID                 string              `json:"job_id"`
	TaskRef               string              `json:"task_ref"`
	Phase                 string              `json:"phase"`
	RuntimeProfile        string              `json:"runtime_profile"`
	SourceDescriptor      SourceDescriptor    `json:"source_descriptor"`
	WorkspaceRequest      *WorkspaceRequest   `json:"workspace_request,omitempty"`
	MergeRequest          *MergeRequest       `json:"merge_request,omitempty"`
	WorkerProtocolRequest map[string]any      `json:"worker_protocol_request,omitempty"`
	AgentEnvironment      *AgentEnvironment   `json:"agent_environment,omitempty"`
	WorkingDir            string              `json:"working_dir"`
	Command               string              `json:"command"`
	Args                  []string            `json:"args"`
	Env                   map[string]string   `json:"env"`
	TimeoutSeconds        int                 `json:"timeout_seconds"`
	ArtifactRules         []map[string]string `json:"artifact_rules"`
}

type AgentEnvironment struct {
	WorkspaceRoot string            `json:"workspace_root,omitempty"`
	SourcePaths   map[string]string `json:"source_paths,omitempty"`
	Env           map[string]string `json:"env,omitempty"`
	RequiredBins  []string          `json:"required_bins,omitempty"`
}

type MergeRequest struct {
	WorkspaceID string                      `json:"workspace_id"`
	Policy      string                      `json:"policy"`
	Slots       map[string]MergeSlotRequest `json:"slots"`
}

type MergeSlotRequest struct {
	Source       WorkspaceSourceRequest `json:"source"`
	SourceRef    string                 `json:"source_ref"`
	TargetRef    string                 `json:"target_ref"`
	BootstrapRef string                 `json:"bootstrap_ref,omitempty"`
}

type WorkspaceRequest struct {
	Mode            string                          `json:"mode"`
	WorkspaceKind   string                          `json:"workspace_kind"`
	WorkspaceID     string                          `json:"workspace_id"`
	FreshnessPolicy string                          `json:"freshness_policy"`
	CleanupPolicy   string                          `json:"cleanup_policy"`
	PublishPolicy   *WorkspacePublishPolicy         `json:"publish_policy,omitempty"`
	Slots           map[string]WorkspaceSlotRequest `json:"slots"`
}

type WorkspacePublishPolicy struct {
	Mode          string `json:"mode"`
	CommitMessage string `json:"commit_message"`
}

type WorkspaceSlotRequest struct {
	Source           WorkspaceSourceRequest `json:"source"`
	Ref              string                 `json:"ref"`
	BootstrapRef     string                 `json:"bootstrap_ref,omitempty"`
	BootstrapBaseRef string                 `json:"bootstrap_base_ref,omitempty"`
	Checkout         string                 `json:"checkout"`
	Access           string                 `json:"access"`
	SyncClass        string                 `json:"sync_class"`
	Ownership        string                 `json:"ownership"`
	Required         bool                   `json:"required"`
}

type WorkspaceSourceRequest struct {
	Kind  string `json:"kind"`
	Alias string `json:"alias"`
}

type ArtifactUpload struct {
	ArtifactID     string `json:"artifact_id"`
	Role           string `json:"role"`
	Digest         string `json:"digest"`
	ByteSize       int    `json:"byte_size"`
	RetentionClass string `json:"retention_class"`
	MediaType      string `json:"media_type,omitempty"`
}

type WorkspaceDescriptor struct {
	WorkspaceKind    string                    `json:"workspace_kind"`
	RuntimeProfile   string                    `json:"runtime_profile"`
	WorkspaceID      string                    `json:"workspace_id"`
	SourceDescriptor SourceDescriptor          `json:"source_descriptor"`
	SlotDescriptors  map[string]map[string]any `json:"slot_descriptors"`
}

type JobResult struct {
	JobID                string              `json:"job_id"`
	Status               string              `json:"status"`
	ExitCode             *int                `json:"exit_code,omitempty"`
	StartedAt            string              `json:"started_at"`
	FinishedAt           string              `json:"finished_at"`
	Summary              string              `json:"summary"`
	LogUploads           []ArtifactUpload    `json:"log_uploads"`
	ArtifactUploads      []ArtifactUpload    `json:"artifact_uploads"`
	WorkspaceDescriptor  WorkspaceDescriptor `json:"workspace_descriptor"`
	WorkerProtocolResult map[string]any      `json:"worker_protocol_result,omitempty"`
	Heartbeat            string              `json:"heartbeat,omitempty"`
}
