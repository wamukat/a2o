package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var projectDocsMachineKeyPattern = regexp.MustCompile(`^[a-z][a-z0-9_]*$`)

func validateProjectDocsConfig(rawDocs any, packagePath string, repos map[string]struct {
	Path  string `yaml:"path"`
	Label string `yaml:"label"`
}) error {
	if rawDocs == nil {
		return nil
	}
	docs, ok := normalizeYAMLValue(rawDocs).(map[string]any)
	if !ok {
		return fmt.Errorf("must be a mapping")
	}
	repoNames := projectRepoNames(repos)
	if rawSurfaces, ok := docs["surfaces"]; ok {
		surfaces, ok := normalizeYAMLValue(rawSurfaces).(map[string]any)
		if !ok || len(surfaces) == 0 {
			return fmt.Errorf("surfaces must be a non-empty mapping")
		}
		for id, rawSurface := range surfaces {
			if !projectDocsMachineKey(id) {
				return fmt.Errorf("surfaces.%s id must be a non-empty machine-readable key", id)
			}
			surface, ok := normalizeYAMLValue(rawSurface).(map[string]any)
			if !ok {
				return fmt.Errorf("surfaces.%s must be a mapping", id)
			}
			repoSlot, err := projectDocsRepoSlot(surface["repoSlot"], repoNames, "surfaces.%s.repoSlot", id)
			if err != nil {
				return err
			}
			if repoSlot == "" {
				repoSlot, err = projectDocsRepoSlot(docs["repoSlot"], repoNames, "repoSlot")
				if err != nil {
					return err
				}
			}
			if repoSlot == "" && len(repoNames) == 1 {
				repoSlot = repoNames[0]
			}
			if repoSlot == "" && len(repoNames) > 1 {
				return fmt.Errorf("surfaces.%s.repoSlot must be provided when multiple repos are declared", id)
			}
			repoRoot := projectDocsRepoRoot(packagePath, repos, repoSlot)
			if err := validateProjectDocsPath(surface["root"], "surfaces."+id+".root", repoRoot, true); err != nil {
				return err
			}
			if err := validateProjectDocsPath(surface["index"], "surfaces."+id+".index", repoRoot, false); err != nil {
				return err
			}
			if err := validateProjectDocsCategories(surface["categories"], repoRoot, "surfaces."+id+".categories"); err != nil {
				return err
			}
			if err := validateProjectDocsLanguages(firstPresent(surface["languages"], docs["languages"])); err != nil {
				return err
			}
			if err := validateProjectDocsStringMap(firstPresent(surface["policy"], docs["policy"]), "surfaces."+id+".policy"); err != nil {
				return err
			}
			if err := validateProjectDocsStringMap(firstPresent(surface["impactPolicy"], docs["impactPolicy"]), "surfaces."+id+".impactPolicy"); err != nil {
				return err
			}
		}
		if err := validateProjectDocsAuthorities(docs["authorities"], packagePath, repos, docs, surfaces); err != nil {
			return err
		}
		return nil
	}
	repoSlot := ""
	if rawRepoSlot, ok := docs["repoSlot"]; ok {
		value, ok := rawRepoSlot.(string)
		if !ok || strings.TrimSpace(value) == "" {
			return fmt.Errorf("repoSlot must be a non-empty string")
		}
		repoSlot = strings.TrimSpace(value)
		if len(repoNames) > 0 && !containsString(repoNames, repoSlot) {
			return fmt.Errorf("repoSlot must match a repos entry: %s", repoSlot)
		}
	} else if len(repoNames) == 1 {
		repoSlot = repoNames[0]
	} else if len(repoNames) > 1 {
		return fmt.Errorf("repoSlot must be provided when multiple repos are declared")
	}
	repoRoot := projectDocsRepoRoot(packagePath, repos, repoSlot)
	if err := validateProjectDocsPath(docs["root"], "root", repoRoot, true); err != nil {
		return err
	}
	if err := validateProjectDocsPath(docs["index"], "index", repoRoot, false); err != nil {
		return err
	}
	if err := validateProjectDocsCategories(docs["categories"], repoRoot, "categories"); err != nil {
		return err
	}
	if err := validateProjectDocsLanguages(docs["languages"]); err != nil {
		return err
	}
	if err := validateProjectDocsStringMap(docs["policy"], "policy"); err != nil {
		return err
	}
	if err := validateProjectDocsStringMap(docs["impactPolicy"], "impactPolicy"); err != nil {
		return err
	}
	if err := validateProjectDocsAuthorities(docs["authorities"], packagePath, repos, docs, nil); err != nil {
		return err
	}
	return nil
}

func projectDocsRepoSlot(rawSlot any, repoNames []string, label string, args ...any) (string, error) {
	if len(args) > 0 {
		label = fmt.Sprintf(label, args...)
	}
	if rawSlot == nil {
		return "", nil
	}
	value, ok := rawSlot.(string)
	if !ok || strings.TrimSpace(value) == "" {
		return "", fmt.Errorf("%s must be a non-empty string", label)
	}
	slot := strings.TrimSpace(value)
	if len(repoNames) > 0 && !containsString(repoNames, slot) {
		return "", fmt.Errorf("%s must match a repos entry: %s", label, slot)
	}
	return slot, nil
}

func firstPresent(primary any, fallback any) any {
	if primary != nil {
		return primary
	}
	return fallback
}

func projectDocsRepoRoot(packagePath string, repos map[string]struct {
	Path  string `yaml:"path"`
	Label string `yaml:"label"`
}, repoSlot string) string {
	repo, ok := repos[repoSlot]
	if !ok {
		return ""
	}
	if strings.TrimSpace(repo.Path) == "" {
		return ""
	}
	if filepath.IsAbs(repo.Path) {
		return filepath.Clean(repo.Path)
	}
	return filepath.Clean(filepath.Join(packagePath, repo.Path))
}

func validateProjectDocsCategories(rawCategories any, repoRoot string, label string) error {
	if rawCategories == nil {
		return nil
	}
	categories, ok := normalizeYAMLValue(rawCategories).(map[string]any)
	if !ok {
		return fmt.Errorf("%s must be a mapping", label)
	}
	for id, rawCategory := range categories {
		if !projectDocsMachineKey(id) {
			return fmt.Errorf("%s.%s id must be a non-empty machine-readable key", label, id)
		}
		category, ok := normalizeYAMLValue(rawCategory).(map[string]any)
		if !ok {
			return fmt.Errorf("%s.%s must be a mapping", label, id)
		}
		if err := validateProjectDocsPath(category["path"], label+"."+id+".path", repoRoot, true); err != nil {
			return err
		}
		if err := validateProjectDocsPath(category["index"], label+"."+id+".index", repoRoot, false); err != nil {
			return err
		}
	}
	return nil
}

func validateProjectDocsAuthorities(rawAuthorities any, packagePath string, repos map[string]struct {
	Path  string `yaml:"path"`
	Label string `yaml:"label"`
}, docs map[string]any, rawSurfaces map[string]any) error {
	if rawAuthorities == nil {
		return nil
	}
	authorities, ok := normalizeYAMLValue(rawAuthorities).(map[string]any)
	if !ok {
		return fmt.Errorf("authorities must be a mapping")
	}
	for id, rawAuthority := range authorities {
		if !projectDocsMachineKey(id) {
			return fmt.Errorf("authorities.%s id must be a non-empty machine-readable key", id)
		}
		authority, ok := normalizeYAMLValue(rawAuthority).(map[string]any)
		if !ok {
			return fmt.Errorf("authorities.%s must be a mapping", id)
		}
		repoSlot, err := projectDocsAuthorityRepoSlot(authority, docs, rawSurfaces, projectRepoNames(repos), id)
		if err != nil {
			return err
		}
		repoRoot := projectDocsRepoRoot(packagePath, repos, repoSlot)
		generated, _ := authority["generated"].(bool)
		if err := validateProjectDocsPath(authority["source"], "authorities."+id+".source", repoRoot, !generated); err != nil {
			return err
		}
		if !generated && repoRoot != "" {
			source, _ := authority["source"].(string)
			if strings.TrimSpace(source) != "" {
				sourcePath := filepath.Join(repoRoot, source)
				if _, err := os.Stat(sourcePath); err != nil {
					if os.IsNotExist(err) {
						return fmt.Errorf("authorities.%s.source file not found: %s", id, source)
					}
					return fmt.Errorf("authorities.%s.source inspect file: %w", id, err)
				}
			}
		}
		if rawDocsPaths, ok := authority["docs"]; ok {
			switch docsPaths := normalizeYAMLValue(rawDocsPaths).(type) {
			case string:
				if err := validateProjectDocsPath(docsPaths, "authorities."+id+".docs", repoRoot, false); err != nil {
					return err
				}
			case []any:
				for index, entry := range docsPaths {
					if docEntry, ok := normalizeYAMLValue(entry).(map[string]any); ok {
						surfaceID, _ := docEntry["surface"].(string)
						if strings.TrimSpace(surfaceID) == "" {
							return fmt.Errorf("authorities.%s.docs[%d].surface must be a non-empty string", id, index)
						}
						surfaceRoot, err := projectDocsSurfaceRepoRoot(packagePath, repos, docs, rawSurfaces, strings.TrimSpace(surfaceID))
						if err != nil {
							return fmt.Errorf("authorities.%s.docs[%d]: %w", id, index, err)
						}
						if err := validateProjectDocsPath(docEntry["path"], fmt.Sprintf("authorities.%s.docs[%d].path", id, index), surfaceRoot, true); err != nil {
							return err
						}
						continue
					}
					if err := validateProjectDocsPath(entry, fmt.Sprintf("authorities.%s.docs[%d]", id, index), repoRoot, true); err != nil {
						return err
					}
				}
			default:
				return fmt.Errorf("authorities.%s.docs must be a string or array of strings/maps", id)
			}
		}
	}
	return nil
}

func projectDocsAuthorityRepoSlot(authority map[string]any, docs map[string]any, rawSurfaces map[string]any, repoNames []string, id string) (string, error) {
	if slot, err := projectDocsRepoSlot(authority["repoSlot"], repoNames, "authorities."+id+".repoSlot"); err != nil || slot != "" {
		return slot, err
	}
	if slot, err := projectDocsRepoSlot(docs["repoSlot"], repoNames, "repoSlot"); err != nil || slot != "" {
		return slot, err
	}
	if len(repoNames) == 1 {
		return repoNames[0], nil
	}
	if len(rawSurfaces) > 0 {
		return "", fmt.Errorf("authorities.%s.repoSlot must be provided when docs.surfaces and multiple repos are declared", id)
	}
	return "", nil
}

func projectDocsSurfaceRepoRoot(packagePath string, repos map[string]struct {
	Path  string `yaml:"path"`
	Label string `yaml:"label"`
}, docs map[string]any, rawSurfaces map[string]any, surfaceID string) (string, error) {
	rawSurface, ok := rawSurfaces[surfaceID]
	if !ok {
		return "", fmt.Errorf("surface not found: %s", surfaceID)
	}
	surface, ok := normalizeYAMLValue(rawSurface).(map[string]any)
	if !ok {
		return "", fmt.Errorf("surfaces.%s must be a mapping", surfaceID)
	}
	repoNames := projectRepoNames(repos)
	slot, err := projectDocsRepoSlot(surface["repoSlot"], repoNames, "surfaces."+surfaceID+".repoSlot")
	if err != nil {
		return "", err
	}
	if slot == "" {
		slot, err = projectDocsRepoSlot(docs["repoSlot"], repoNames, "repoSlot")
		if err != nil {
			return "", err
		}
	}
	if slot == "" && len(repoNames) == 1 {
		slot = repoNames[0]
	}
	if slot == "" && len(repoNames) > 1 {
		return "", fmt.Errorf("surfaces.%s.repoSlot must be provided when multiple repos are declared", surfaceID)
	}
	return projectDocsRepoRoot(packagePath, repos, slot), nil
}

func validateProjectDocsLanguages(rawLanguages any) error {
	if rawLanguages == nil {
		return nil
	}
	languages, ok := normalizeYAMLValue(rawLanguages).(map[string]any)
	if !ok {
		return fmt.Errorf("languages must be a mapping")
	}
	if rawPrimary, ok := languages["primary"]; ok {
		primary, ok := rawPrimary.(string)
		if !ok || strings.TrimSpace(primary) == "" {
			return fmt.Errorf("languages.primary must be a non-empty string")
		}
	}
	for _, key := range []string{"secondary", "required"} {
		rawList, ok := languages[key]
		if !ok {
			continue
		}
		list, ok := normalizeYAMLValue(rawList).([]any)
		if !ok {
			return fmt.Errorf("languages.%s must be an array of non-empty strings", key)
		}
		for index, rawEntry := range list {
			entry, ok := rawEntry.(string)
			if !ok || strings.TrimSpace(entry) == "" {
				return fmt.Errorf("languages.%s[%d] must be a non-empty string", key, index)
			}
		}
	}
	return nil
}

func validateProjectDocsStringMap(rawMap any, label string) error {
	if rawMap == nil {
		return nil
	}
	values, ok := normalizeYAMLValue(rawMap).(map[string]any)
	if !ok {
		return fmt.Errorf("%s must be a mapping", label)
	}
	for key := range values {
		if strings.TrimSpace(key) == "" {
			return fmt.Errorf("%s keys must be non-empty strings", label)
		}
	}
	return nil
}

func validateProjectDocsPath(rawPath any, label string, repoRoot string, required bool) error {
	if rawPath == nil {
		if required {
			return fmt.Errorf("%s must be a non-empty repo-slot-relative path", label)
		}
		return nil
	}
	path, ok := rawPath.(string)
	if !ok || strings.TrimSpace(path) == "" {
		return fmt.Errorf("%s must be a non-empty repo-slot-relative path", label)
	}
	if filepath.IsAbs(path) {
		return fmt.Errorf("%s must be relative to the docs repo slot", label)
	}
	for _, part := range strings.FieldsFunc(filepath.ToSlash(path), func(r rune) bool { return r == '/' }) {
		if part == ".." {
			return fmt.Errorf("%s must stay inside the docs repo slot", label)
		}
	}
	if repoRoot == "" {
		return nil
	}
	absRepoRoot, err := filepath.Abs(repoRoot)
	if err != nil {
		return fmt.Errorf("resolve docs repo slot root: %w", err)
	}
	absPath, err := filepath.Abs(filepath.Join(absRepoRoot, path))
	if err != nil {
		return fmt.Errorf("%s resolve path: %w", label, err)
	}
	if absPath != absRepoRoot && !strings.HasPrefix(absPath, absRepoRoot+string(os.PathSeparator)) {
		return fmt.Errorf("%s must stay inside the docs repo slot", label)
	}
	realRoot, err := filepath.EvalSymlinks(absRepoRoot)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("resolve docs repo slot root: %w", err)
	}
	existingPath, err := nearestExistingPath(absPath)
	if err != nil {
		return fmt.Errorf("%s inspect path: %w", label, err)
	}
	realExistingPath, err := filepath.EvalSymlinks(existingPath)
	if err != nil {
		return fmt.Errorf("%s resolve path: %w", label, err)
	}
	if realExistingPath != realRoot && !strings.HasPrefix(realExistingPath, realRoot+string(os.PathSeparator)) {
		return fmt.Errorf("%s must stay inside the docs repo slot", label)
	}
	return nil
}

func nearestExistingPath(path string) (string, error) {
	current := path
	for {
		if _, err := os.Lstat(current); err == nil {
			return current, nil
		} else if !os.IsNotExist(err) {
			return "", err
		}
		parent := filepath.Dir(current)
		if parent == current {
			return "", os.ErrNotExist
		}
		current = parent
	}
}

func projectDocsMachineKey(value string) bool {
	if strings.TrimSpace(value) == "" {
		return false
	}
	return projectDocsMachineKeyPattern.MatchString(value)
}
