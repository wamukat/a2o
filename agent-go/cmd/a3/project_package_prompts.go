package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

func validateProjectPromptsConfig(runtimePayload map[string]any, packagePath string, repoNames []string) error {
	rawPrompts, ok := runtimePayload["prompts"]
	if !ok {
		return nil
	}
	prompts, ok := normalizeYAMLValue(rawPrompts).(map[string]any)
	if !ok {
		return fmt.Errorf("must be a mapping")
	}
	if rawSystem, ok := prompts["system"]; ok {
		system, ok := normalizeYAMLValue(rawSystem).(map[string]any)
		if !ok {
			return fmt.Errorf("system must be a mapping")
		}
		if err := validatePromptPath(system["file"], "system.file", packagePath, true); err != nil {
			return err
		}
	}
	basePhases, _ := normalizeYAMLValue(prompts["phases"]).(map[string]any)
	if err := validatePromptPhaseMapping(prompts["phases"], "phases", packagePath); err != nil {
		return err
	}
	if rawRepoSlots, ok := prompts["repoSlots"]; ok {
		repoSlots, ok := normalizeYAMLValue(rawRepoSlots).(map[string]any)
		if !ok {
			return fmt.Errorf("repoSlots must be a mapping")
		}
		for slot, rawSlotConfig := range repoSlots {
			if strings.TrimSpace(slot) == "" {
				return fmt.Errorf("repoSlots keys must be non-empty strings")
			}
			if len(repoNames) > 0 && !containsString(repoNames, slot) {
				return fmt.Errorf("repoSlots.%s must match a repos entry", slot)
			}
			slotConfig, ok := normalizeYAMLValue(rawSlotConfig).(map[string]any)
			if !ok {
				return fmt.Errorf("repoSlots.%s must be a mapping", slot)
			}
			if err := validatePromptPhaseMapping(slotConfig["phases"], "repoSlots."+slot+".phases", packagePath); err != nil {
				return err
			}
			slotPhases, _ := normalizeYAMLValue(slotConfig["phases"]).(map[string]any)
			if err := validateRepoSlotPromptSkillAddons(slot, basePhases, slotPhases); err != nil {
				return err
			}
		}
	}
	return nil
}

func validatePromptBackedPhaseSkills(runtimePayload map[string]any) error {
	phases, _ := normalizeYAMLValue(runtimePayload["phases"]).(map[string]any)
	prompts, _ := normalizeYAMLValue(runtimePayload["prompts"]).(map[string]any)
	promptPhases, _ := normalizeYAMLValue(prompts["phases"]).(map[string]any)
	for _, phaseName := range []string{"implementation", "review"} {
		phase, ok := normalizeYAMLValue(phases[phaseName]).(map[string]any)
		if !ok {
			continue
		}
		if _, hasSkill := phase["skill"]; hasSkill {
			continue
		}
		if promptPhaseHasAuthoringContent(promptPhases[phaseName]) {
			continue
		}
		return fmt.Errorf("%s.skill must be provided", phaseName)
	}
	return nil
}

func promptPhaseHasAuthoringContent(rawPhase any) bool {
	phase, ok := normalizeYAMLValue(rawPhase).(map[string]any)
	if !ok {
		return false
	}
	if strings.TrimSpace(scalarString(phase["prompt"])) != "" {
		return true
	}
	skills, ok := normalizeYAMLValue(phase["skills"]).([]any)
	return ok && len(skills) > 0
}

func validatePromptPhaseMapping(rawPhases any, label string, packagePath string) error {
	if rawPhases == nil {
		return nil
	}
	phases, ok := normalizeYAMLValue(rawPhases).(map[string]any)
	if !ok {
		return fmt.Errorf("%s must be a mapping", label)
	}
	for phase, rawPhaseConfig := range phases {
		if strings.TrimSpace(phase) == "" {
			return fmt.Errorf("%s keys must be non-empty strings", label)
		}
		if !containsString([]string{"implementation", "implementation_rework", "review", "parent_review", "verification", "remediation", "metrics", "decomposition"}, phase) {
			return fmt.Errorf("%s.%s is not a supported prompt phase", label, phase)
		}
		phaseConfig, ok := normalizeYAMLValue(rawPhaseConfig).(map[string]any)
		if !ok {
			return fmt.Errorf("%s.%s must be a mapping", label, phase)
		}
		if _, ok := phaseConfig["childDraftTemplate"]; ok && phase != "decomposition" {
			return fmt.Errorf("%s.%s.childDraftTemplate is only supported for decomposition", label, phase)
		}
		if err := validatePromptPath(phaseConfig["prompt"], label+"."+phase+".prompt", packagePath, false); err != nil {
			return err
		}
		if err := validatePromptStringList(phaseConfig["skills"], label+"."+phase+".skills", packagePath); err != nil {
			return err
		}
		if err := validatePromptPath(phaseConfig["childDraftTemplate"], label+"."+phase+".childDraftTemplate", packagePath, false); err != nil {
			return err
		}
	}
	return nil
}

func validatePromptPath(rawPath any, label string, packagePath string, required bool) error {
	if rawPath == nil {
		if required {
			return fmt.Errorf("%s must be a non-empty string", label)
		}
		return nil
	}
	path, ok := rawPath.(string)
	if !ok || strings.TrimSpace(path) == "" {
		return fmt.Errorf("%s must be a non-empty string", label)
	}
	if filepath.IsAbs(path) {
		return fmt.Errorf("%s must be relative to the project package root", label)
	}
	root, err := filepath.Abs(packagePath)
	if err != nil {
		return fmt.Errorf("resolve project package root: %w", err)
	}
	absPath, err := filepath.Abs(filepath.Join(root, path))
	if err != nil {
		return fmt.Errorf("%s resolve path: %w", label, err)
	}
	if absPath != root && !strings.HasPrefix(absPath, root+string(os.PathSeparator)) {
		return fmt.Errorf("%s must stay inside the project package root", label)
	}
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return fmt.Errorf("resolve project package root: %w", err)
	}
	realPath, err := filepath.EvalSymlinks(absPath)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("%s file not found: %s", label, path)
		}
		return fmt.Errorf("%s resolve file: %w", label, err)
	}
	if realPath != realRoot && !strings.HasPrefix(realPath, realRoot+string(os.PathSeparator)) {
		return fmt.Errorf("%s must stay inside the project package root", label)
	}
	info, err := os.Stat(absPath)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("%s file not found: %s", label, path)
		}
		return fmt.Errorf("%s inspect file: %w", label, err)
	}
	if info.IsDir() {
		return fmt.Errorf("%s must reference a file: %s", label, path)
	}
	body, err := os.ReadFile(absPath)
	if err != nil {
		return fmt.Errorf("%s read file: %w", label, err)
	}
	if !utf8.Valid(body) {
		return fmt.Errorf("%s must be UTF-8 text: %s", label, path)
	}
	return nil
}

func validatePromptStringList(rawList any, label string, packagePath string) error {
	if rawList == nil {
		return nil
	}
	list, ok := normalizeYAMLValue(rawList).([]any)
	if !ok {
		return fmt.Errorf("%s must be an array of non-empty strings", label)
	}
	seen := map[string]bool{}
	for index, rawEntry := range list {
		entry, ok := rawEntry.(string)
		if !ok || strings.TrimSpace(entry) == "" {
			return fmt.Errorf("%s[%d] must be a non-empty string", label, index)
		}
		if seen[entry] {
			return fmt.Errorf("%s contains duplicate skill file: %s", label, entry)
		}
		seen[entry] = true
		if err := validatePromptPath(entry, fmt.Sprintf("%s[%d]", label, index), packagePath, true); err != nil {
			return err
		}
	}
	return nil
}

func validateRepoSlotPromptSkillAddons(slot string, basePhases map[string]any, slotPhases map[string]any) error {
	for phase, rawSlotPhase := range slotPhases {
		slotSkills := promptPhaseSkillFiles(rawSlotPhase)
		if len(slotSkills) == 0 {
			continue
		}
		basePhase := promptBasePhaseForAddon(phase, basePhases)
		baseSkills := promptPhaseSkillFiles(basePhases[basePhase])
		for _, skill := range slotSkills {
			if containsString(baseSkills, skill) {
				return fmt.Errorf("repoSlots.%s.phases.%s.skills duplicates phases.%s.skills entry: %s", slot, phase, basePhase, skill)
			}
		}
	}
	return nil
}

func promptBasePhaseForAddon(phase string, basePhases map[string]any) string {
	if phase == "implementation_rework" {
		if len(promptPhaseSkillFiles(basePhases["implementation_rework"])) == 0 && promptPhaseConfigEmptyRaw(basePhases["implementation_rework"]) {
			if !promptPhaseConfigEmptyRaw(basePhases["implementation"]) {
				return "implementation"
			}
		}
	}
	return phase
}

func promptPhaseConfigEmptyRaw(rawPhase any) bool {
	phase, ok := normalizeYAMLValue(rawPhase).(map[string]any)
	if !ok {
		return true
	}
	prompt, _ := phase["prompt"].(string)
	childDraftTemplate, _ := phase["childDraftTemplate"].(string)
	return strings.TrimSpace(prompt) == "" && strings.TrimSpace(childDraftTemplate) == "" && len(promptPhaseSkillFiles(rawPhase)) == 0
}

func promptPhaseSkillFiles(rawPhase any) []string {
	phase, ok := normalizeYAMLValue(rawPhase).(map[string]any)
	if !ok {
		return nil
	}
	rawSkills, ok := normalizeYAMLValue(phase["skills"]).([]any)
	if !ok {
		return nil
	}
	skills := make([]string, 0, len(rawSkills))
	for _, rawSkill := range rawSkills {
		skill, ok := rawSkill.(string)
		if ok {
			skills = append(skills, skill)
		}
	}
	return skills
}
