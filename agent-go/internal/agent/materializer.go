package agent

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
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
		prepared.SlotDescriptors[slotName] = descriptor
		prepared.cleanupOperations = append(prepared.cleanupOperations, cleanupOperation{
			sourceRoot: sourceRoot,
			slotPath:   slotPath,
		})
	}
	return prepared, nil
}

func (m WorkspaceMaterializer) Cleanup(prepared PreparedWorkspace) error {
	var firstErr error
	for _, operation := range prepared.cleanupOperations {
		if err := runGit(operation.sourceRoot, "worktree", "remove", "--force", operation.slotPath); err != nil && firstErr == nil {
			firstErr = err
		}
		if err := runGit(operation.sourceRoot, "worktree", "prune"); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	if err := os.RemoveAll(prepared.Root); err != nil && firstErr == nil {
		firstErr = err
	}
	return firstErr
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
	if err := runGit(sourceRoot, "worktree", "prune"); err != nil {
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

func trimTrailingNewline(value string) string {
	for len(value) > 0 && (value[len(value)-1] == '\n' || value[len(value)-1] == '\r') {
		value = value[:len(value)-1]
	}
	return value
}
