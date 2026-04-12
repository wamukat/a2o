package agent

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

type WorkspaceMaterializer struct {
	WorkspaceRoot string
	SourceAliases map[string]string
}

type PreparedWorkspace struct {
	Root              string
	SlotDescriptors   map[string]map[string]any
	cleanupOperations []cleanupOperation
}

type cleanupOperation struct {
	sourceRoot string
	slotPath   string
}

func (m WorkspaceMaterializer) Prepare(request WorkspaceRequest) (PreparedWorkspace, error) {
	root, err := m.workspaceRoot(request.WorkspaceID)
	if err != nil {
		return PreparedWorkspace{}, err
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return PreparedWorkspace{}, err
	}

	prepared := PreparedWorkspace{
		Root:            root,
		SlotDescriptors: map[string]map[string]any{},
	}
	for slotName, slot := range request.Slots {
		if !slot.Required {
			continue
		}
		if slot.Source.Kind != "local_git" {
			return PreparedWorkspace{}, fmt.Errorf("unsupported source kind for %s: %s", slotName, slot.Source.Kind)
		}
		if slot.Checkout != "worktree_detached" {
			return PreparedWorkspace{}, fmt.Errorf("unsupported checkout for %s: %s", slotName, slot.Checkout)
		}
		sourceRoot, err := m.sourceRoot(slot.Source.Alias)
		if err != nil {
			return PreparedWorkspace{}, err
		}
		slotPath := filepath.Join(root, slotDirectory(slotName))
		descriptor, err := m.materializeSlot(sourceRoot, slotPath, slot)
		if err != nil {
			return PreparedWorkspace{}, err
		}
		if err := writeSlotMetadata(slotPath, sourceRoot, request, slotName, slot); err != nil {
			return PreparedWorkspace{}, err
		}
		prepared.SlotDescriptors[slotName] = descriptor
		prepared.cleanupOperations = append(prepared.cleanupOperations, cleanupOperation{
			sourceRoot: sourceRoot,
			slotPath:   slotPath,
		})
	}
	if err := writeWorkspaceMetadata(root, request); err != nil {
		return PreparedWorkspace{}, err
	}
	return prepared, nil
}

func (m WorkspaceMaterializer) Cleanup(prepared PreparedWorkspace) error {
	var firstErr error
	for _, operation := range prepared.cleanupOperations {
		if err := runGit(operation.sourceRoot, "worktree", "remove", "--force", operation.slotPath); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	if err := os.RemoveAll(prepared.Root); err != nil && firstErr == nil {
		firstErr = err
	}
	return firstErr
}

func RefreshWorkspaceEvidence(prepared PreparedWorkspace) error {
	for _, descriptor := range prepared.SlotDescriptors {
		runtimePath, ok := descriptor["runtime_path"].(string)
		if !ok || runtimePath == "" {
			return fmt.Errorf("slot descriptor runtime_path is required")
		}
		changedFiles, err := gitChangedPaths(runtimePath)
		if err != nil {
			return err
		}
		patch, err := gitPatch(runtimePath)
		if err != nil {
			return err
		}
		dirtyAfter, err := gitDirty(runtimePath)
		if err != nil {
			return err
		}
		descriptor["changed_files"] = changedFiles
		descriptor["patch"] = patch
		descriptor["dirty_after"] = dirtyAfter
	}
	return nil
}

func gitChangedPaths(root string) ([]string, error) {
	out, err := gitOutput(root, "status", "--porcelain", "--untracked-files=all", "--", ".", ":(exclude).a3")
	if err != nil {
		return nil, err
	}
	paths := []string{}
	for _, line := range strings.FieldsFunc(out, func(char rune) bool { return char == '\n' || char == '\r' }) {
		if len(line) < 4 {
			continue
		}
		path := line[3:]
		if path == "" {
			continue
		}
		if _, after, found := strings.Cut(path, " -> "); found {
			path = after
		}
		paths = append(paths, path)
	}
	sort.Strings(paths)
	return uniqueStrings(paths), nil
}

func uniqueStrings(values []string) []string {
	if len(values) == 0 {
		return values
	}
	unique := values[:1]
	for _, value := range values[1:] {
		if value != unique[len(unique)-1] {
			unique = append(unique, value)
		}
	}
	return unique
}

func (m WorkspaceMaterializer) workspaceRoot(workspaceID string) (string, error) {
	if m.WorkspaceRoot == "" {
		return "", fmt.Errorf("workspace root is required")
	}
	if workspaceID == "" {
		return "", fmt.Errorf("workspace id is required")
	}
	return filepath.Abs(filepath.Join(m.WorkspaceRoot, safeID(workspaceID)))
}

func (m WorkspaceMaterializer) sourceRoot(alias string) (string, error) {
	if alias == "" {
		return "", fmt.Errorf("source alias is required")
	}
	path := m.SourceAliases[alias]
	if path == "" {
		return "", fmt.Errorf("source alias is not configured: %s", alias)
	}
	return filepath.Abs(path)
}

func (m WorkspaceMaterializer) materializeSlot(sourceRoot, slotPath string, slot WorkspaceSlotRequest) (map[string]any, error) {
	if dirty, err := gitDirty(sourceRoot); err != nil {
		return nil, err
	} else if dirty {
		return nil, fmt.Errorf("source alias %s is dirty before materialization", slot.Source.Alias)
	}
	if err := os.RemoveAll(slotPath); err != nil {
		return nil, err
	}
	if err := runGit(sourceRoot, "worktree", "add", "--force", "--detach", slotPath, slot.Ref); err != nil {
		return nil, err
	}
	head, err := gitOutput(slotPath, "rev-parse", "HEAD")
	if err != nil {
		return nil, err
	}
	dirtyAfter, err := gitDirty(slotPath)
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"runtime_path":  slotPath,
		"source_kind":   slot.Source.Kind,
		"source_alias":  slot.Source.Alias,
		"checkout":      slot.Checkout,
		"requested_ref": slot.Ref,
		"resolved_head": head,
		"dirty_before":  false,
		"dirty_after":   dirtyAfter,
		"access":        slot.Access,
	}, nil
}

func gitPatch(root string) (string, error) {
	if err := runGit(root, "add", "-N", "--", ".", ":(exclude).a3"); err != nil {
		return "", err
	}
	cmd := exec.Command("git", "-C", root, "diff", "--binary", "HEAD", "--", ".", ":(exclude).a3")
	out, err := cmd.Output()
	if err != nil {
		return "", gitError([]string{"diff", "--binary", "HEAD", "--", ".", ":(exclude).a3"}, err)
	}
	return string(out), nil
}

func gitDirty(root string) (bool, error) {
	out, err := gitOutput(root, "status", "--porcelain", "--untracked-files=all")
	if err != nil {
		return false, err
	}
	return out != "", nil
}

func gitOutput(root string, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	out, err := cmd.Output()
	if err != nil {
		return "", gitError(args, err)
	}
	return trimTrailingNewline(string(out)), nil
}

func runGit(root string, args ...string) error {
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("git %v failed: %w: %s", args, err, trimTrailingNewline(string(out)))
	}
	return nil
}

func gitError(args []string, err error) error {
	if exitErr, ok := err.(*exec.ExitError); ok {
		return fmt.Errorf("git %v failed: %w: %s", args, err, trimTrailingNewline(string(exitErr.Stderr)))
	}
	return fmt.Errorf("git %v failed: %w", args, err)
}

func slotDirectory(slotName string) string {
	switch slotName {
	case "repo_alpha":
		return "repo-alpha"
	case "repo_beta":
		return "repo-beta"
	default:
		return safeID(slotName)
	}
}

func writeWorkspaceMetadata(root string, request WorkspaceRequest) error {
	metadataDir := filepath.Join(root, ".a3")
	if err := os.MkdirAll(metadataDir, 0o755); err != nil {
		return err
	}
	requirements := []map[string]string{}
	slotNames := make([]string, 0, len(request.Slots))
	for slotName := range request.Slots {
		slotNames = append(slotNames, slotName)
	}
	sort.Strings(slotNames)
	for _, slotName := range slotNames {
		requirements = append(requirements, map[string]string{
			"repo_slot":  slotName,
			"sync_class": "copy",
		})
	}
	payload := map[string]any{
		"workspace_kind":    request.WorkspaceKind,
		"source_type":       "branch_head",
		"source_ref":        workspaceSourceRef(request),
		"slot_requirements": requirements,
	}
	return writeMetadataJSON(filepath.Join(metadataDir, "workspace.json"), payload)
}

func writeSlotMetadata(slotPath string, sourceRoot string, request WorkspaceRequest, slotName string, slot WorkspaceSlotRequest) error {
	metadataDir := filepath.Join(slotPath, ".a3")
	if err := os.MkdirAll(metadataDir, 0o755); err != nil {
		return err
	}
	payload := map[string]any{
		"workspace_kind":   request.WorkspaceKind,
		"repo_slot":        slotName,
		"repo_source_root": sourceRoot,
		"sync_class":       "copy",
		"source_type":      "branch_head",
		"source_ref":       slot.Ref,
	}
	if err := writeMetadataJSON(filepath.Join(metadataDir, "slot.json"), payload); err != nil {
		return err
	}
	return writeMetadataJSON(filepath.Join(metadataDir, "materialized.json"), map[string]any{
		"workspace_kind": request.WorkspaceKind,
		"source_type":    "branch_head",
		"source_ref":     slot.Ref,
	})
}

func workspaceSourceRef(request WorkspaceRequest) string {
	for _, slot := range request.Slots {
		return slot.Ref
	}
	return ""
}

func writeMetadataJSON(path string, payload map[string]any) error {
	content, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return err
	}
	content = append(content, '\n')
	return os.WriteFile(path, content, 0o644)
}

func trimTrailingNewline(value string) string {
	for len(value) > 0 && (value[len(value)-1] == '\n' || value[len(value)-1] == '\r') {
		value = value[:len(value)-1]
	}
	return value
}
