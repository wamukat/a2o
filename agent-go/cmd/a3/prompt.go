package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

type projectPromptYAML struct {
	Runtime struct {
		Prompts promptConfigYAML `yaml:"prompts"`
		Phases  map[string]struct {
			Skill any `yaml:"skill"`
		} `yaml:"phases"`
	} `yaml:"runtime"`
}

type promptConfigYAML struct {
	System struct {
		File string `yaml:"file"`
	} `yaml:"system"`
	Phases    map[string]promptPhaseYAML    `yaml:"phases"`
	RepoSlots map[string]promptRepoSlotYAML `yaml:"repoSlots"`
}

type promptRepoSlotYAML struct {
	Phases map[string]promptPhaseYAML `yaml:"phases"`
}

type promptPhaseYAML struct {
	Prompt             string   `yaml:"prompt"`
	Skills             []string `yaml:"skills"`
	ChildDraftTemplate string   `yaml:"childDraftTemplate"`
}

type promptLayerPreview struct {
	Kind    string
	Title   string
	Path    string
	Content string
	Detail  string
}

type promptRepoSlotFlags []string

func (f *promptRepoSlotFlags) String() string {
	return strings.Join(*f, ",")
}

func (f *promptRepoSlotFlags) Set(value string) error {
	for _, entry := range strings.Split(value, ",") {
		slot := strings.TrimSpace(entry)
		if slot == "" {
			continue
		}
		*f = append(*f, slot)
	}
	return nil
}

func runPrompt(args []string, stdout io.Writer, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "missing prompt subcommand")
		return 2
	}
	switch args[0] {
	case "preview":
		return runPromptPreview(args[1:], stdout, stderr)
	case "help", "-h", "--help":
		printPromptUsage(stdout)
		return 0
	default:
		fmt.Fprintf(stderr, "unknown prompt subcommand: %s\n", args[0])
		printPromptUsage(stderr)
		return 2
	}
}

func printPromptUsage(w io.Writer) {
	fmt.Fprintln(w, "usage:")
	fmt.Fprintln(w, "  a2o prompt preview --phase PHASE [--package DIR] [--config project-test.yaml] [--repo-slot SLOT]... [--task-kind child|parent|single] [--prior-review-feedback] TASK_REF")
}

func runPromptPreview(args []string, stdout io.Writer, stderr io.Writer) int {
	flags := flag.NewFlagSet("a2o prompt preview", flag.ContinueOnError)
	flags.SetOutput(stderr)
	packagePath := flags.String("package", "", "project package directory")
	configPath := flags.String("config", "", "project config file; defaults to project.yaml under --package")
	workspaceRoot := flags.String("workspace", ".", "workspace root used when discovering ./a2o-project or ./project-package")
	phase := flags.String("phase", "", "runtime phase to preview")
	var repoSlots promptRepoSlotFlags
	flags.Var(&repoSlots, "repo-slot", "optional repo slot used for repo-slot prompt addons; repeat or comma-separate for multi-repo preview")
	taskKind := flags.String("task-kind", "child", "task kind: child, parent, or single")
	priorReviewFeedback := flags.Bool("prior-review-feedback", false, "preview implementation_rework prompt profile")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if flags.NArg() != 1 {
		printUserFacingError(stderr, fmt.Errorf("usage: a2o prompt preview --phase PHASE TASK_REF"))
		return 2
	}
	taskRef := strings.TrimSpace(flags.Arg(0))
	if taskRef == "" {
		printUserFacingError(stderr, fmt.Errorf("task ref is required"))
		return 2
	}
	context, err := loadPromptCommandContext(*packagePath, *configPath, *workspaceRoot)
	if err != nil {
		printUserFacingError(stderr, err)
		return 1
	}
	profile, err := promptProfileForPreview(*phase, *taskKind, *priorReviewFeedback)
	if err != nil {
		printUserFacingError(stderr, err)
		return 2
	}
	selectedRepoSlots := normalizePromptPreviewRepoSlots(repoSlots)
	layers, err := buildPromptPreviewLayers(context, profile, *phase, selectedRepoSlots, taskRef, *taskKind, *priorReviewFeedback)
	if err != nil {
		printUserFacingError(stderr, err)
		return 1
	}
	fmt.Fprintf(stdout, "prompt_preview task_ref=%s phase=%s profile=%s package=%s config=%s\n", taskRef, strings.TrimSpace(*phase), profile, context.packagePath, context.configPath)
	if len(selectedRepoSlots) != 0 {
		fmt.Fprintf(stdout, "prompt_preview_repo_slots slots=%s status=selected\n", strings.Join(selectedRepoSlots, ","))
	} else {
		fmt.Fprintln(stdout, "prompt_preview_repo_slots slots= status=not_selected reason=no_repo_slot_argument")
	}
	for index, layer := range layers {
		fmt.Fprintf(stdout, "--- prompt_layer index=%d kind=%s title=%s ---\n", index+1, layer.Kind, singleLine(layer.Title))
		if layer.Path != "" {
			fmt.Fprintf(stdout, "path=%s\n", layer.Path)
		}
		if layer.Detail != "" {
			fmt.Fprintf(stdout, "detail=%s\n", singleLine(layer.Detail))
		}
		if strings.TrimSpace(layer.Content) == "" {
			fmt.Fprintln(stdout, "(empty)")
		} else {
			fmt.Fprintln(stdout, strings.TrimRight(layer.Content, "\n"))
		}
	}
	fmt.Fprintln(stdout, "--- prompt_composed_instruction ---")
	fmt.Fprintln(stdout, composedPromptPreview(layers))
	fmt.Fprintln(stdout, "prompt_preview_status=ok mutation=none")
	return 0
}

func normalizePromptPreviewRepoSlots(values []string) []string {
	seen := map[string]bool{}
	slots := []string{}
	for _, value := range values {
		for _, entry := range strings.Split(value, ",") {
			slot := strings.TrimSpace(entry)
			if slot == "" || seen[slot] {
				continue
			}
			seen[slot] = true
			slots = append(slots, slot)
		}
	}
	return slots
}

type promptCommandContext struct {
	packagePath string
	configPath  string
	config      projectPromptYAML
}

func loadPromptCommandContext(packagePath string, configPath string, workspaceRoot string) (promptCommandContext, error) {
	absWorkspaceRoot, err := filepath.Abs(workspaceRoot)
	if err != nil {
		return promptCommandContext{}, fmt.Errorf("resolve workspace root: %w", err)
	}
	resolvedPackagePath, err := resolveBootstrapPackagePath(packagePath, absWorkspaceRoot)
	if err != nil {
		return promptCommandContext{}, err
	}
	absPackagePath, err := filepath.Abs(resolvedPackagePath)
	if err != nil {
		return promptCommandContext{}, fmt.Errorf("resolve package path: %w", err)
	}
	effectiveConfigPath := filepath.Join(absPackagePath, "project.yaml")
	if strings.TrimSpace(configPath) != "" {
		effectiveConfigPath = strings.TrimSpace(configPath)
		if !filepath.IsAbs(effectiveConfigPath) {
			effectiveConfigPath = filepath.Join(absPackagePath, effectiveConfigPath)
		}
	}
	absConfigPath, err := filepath.Abs(effectiveConfigPath)
	if err != nil {
		return promptCommandContext{}, fmt.Errorf("resolve project config path: %w", err)
	}
	if _, err := loadProjectPackageConfigFile(absConfigPath); err != nil {
		return promptCommandContext{}, err
	}
	body, err := os.ReadFile(absConfigPath)
	if err != nil {
		return promptCommandContext{}, fmt.Errorf("read project config: %w", err)
	}
	var config projectPromptYAML
	if err := yaml.Unmarshal(body, &config); err != nil {
		return promptCommandContext{}, fmt.Errorf("parse project config: %w", err)
	}
	if config.Runtime.Prompts.Phases == nil {
		config.Runtime.Prompts.Phases = map[string]promptPhaseYAML{}
	}
	if config.Runtime.Prompts.RepoSlots == nil {
		config.Runtime.Prompts.RepoSlots = map[string]promptRepoSlotYAML{}
	}
	return promptCommandContext{packagePath: absPackagePath, configPath: absConfigPath, config: config}, nil
}

func promptProfileForPreview(phase string, taskKind string, priorReviewFeedback bool) (string, error) {
	phase = strings.TrimSpace(phase)
	taskKind = strings.TrimSpace(taskKind)
	if phase == "" {
		return "", fmt.Errorf("--phase is required")
	}
	if !containsString([]string{"implementation", "review", "verification", "remediation", "metrics", "decomposition"}, phase) {
		return "", fmt.Errorf("--phase must be one of implementation, review, verification, remediation, metrics, decomposition")
	}
	if !containsString([]string{"child", "parent", "single"}, taskKind) {
		return "", fmt.Errorf("--task-kind must be child, parent, or single")
	}
	if phase == "implementation" && priorReviewFeedback {
		return "implementation_rework", nil
	}
	if phase == "review" && taskKind == "parent" {
		return "parent_review", nil
	}
	return phase, nil
}

func buildPromptPreviewLayers(context promptCommandContext, profile string, runtimePhase string, repoSlots []string, taskRef string, taskKind string, priorReviewFeedback bool) ([]promptLayerPreview, error) {
	layers := []promptLayerPreview{}
	if promptPreviewHasCoreInstruction(runtimePhase) {
		coreSkill := coreSkillForPromptPreview(context.config, runtimePhase, profile)
		layers = append(layers, promptLayerPreview{
			Kind:    "a2o_core_instruction",
			Title:   "A2O core instruction",
			Content: coreSkill,
			Detail:  coreSkillDetail(runtimePhase, profile),
		})
	}
	prompts := context.config.Runtime.Prompts
	if strings.TrimSpace(prompts.System.File) != "" {
		layer, err := readPromptLayer(context.packagePath, "project_system_prompt", prompts.System.File)
		if err != nil {
			return nil, err
		}
		layers = append(layers, layer)
	}
	effectiveProfile, phaseConfig := promptPreviewPhaseResolution(prompts.Phases, profile)
	phaseLayers, err := promptPhaseLayers(context.packagePath, "project_phase", "decomposition_child_draft_template", effectiveProfile, phaseConfig)
	if err != nil {
		return nil, err
	}
	layers = append(layers, phaseLayers...)
	if len(repoSlots) != 0 {
		for _, repoSlot := range repoSlots {
			slotConfig, ok := prompts.RepoSlots[repoSlot]
			if !ok {
				return nil, fmt.Errorf("repo slot %q is not configured under runtime.prompts.repoSlots", repoSlot)
			}
			repoSlotLayers, err := promptPhaseLayers(context.packagePath, "repo_slot_phase", "repo_slot_decomposition_child_draft_template", profile, slotConfig.Phases[profile])
			if err != nil {
				return nil, err
			}
			if len(repoSlotLayers) == 0 {
				layers = append(layers, promptLayerPreview{
					Kind:   "repo_slot_phase",
					Title:  "repo slot " + repoSlot,
					Detail: "no repo-slot prompt or skill addons for profile=" + profile,
				})
			} else {
				for i := range repoSlotLayers {
					repoSlotLayers[i].Detail = repoSlot + " " + repoSlotLayers[i].Detail
				}
				layers = append(layers, repoSlotLayers...)
			}
		}
	} else if len(prompts.RepoSlots) > 0 {
		slots := make([]string, 0, len(prompts.RepoSlots))
		for slot := range prompts.RepoSlots {
			slots = append(slots, slot)
		}
		sort.Strings(slots)
		layers = append(layers, promptLayerPreview{
			Kind:   "repo_slot_phase",
			Title:  "repo slot addons",
			Detail: "available=" + strings.Join(slots, ",") + " action=rerun with --repo-slot SLOT, repeatable in edit_scope order for multi-repo preview",
		})
	}
	if promptPreviewHasTicketInstruction(runtimePhase) {
		layers = append(layers, promptLayerPreview{
			Kind:    "ticket_phase_instruction",
			Title:   "ticket " + taskRef,
			Content: "Task: " + taskRef,
			Detail:  fmt.Sprintf("task_kind=%s phase=%s profile=%s prior_review_feedback=%t", strings.TrimSpace(taskKind), strings.TrimSpace(runtimePhase), profile, priorReviewFeedback),
		})
	}
	layers = append(layers, promptLayerPreview{
		Kind:    "task_runtime_data",
		Title:   "runtime task data",
		Content: fmt.Sprintf("task_ref=%s\ntask_kind=%s\nphase=%s\nprofile=%s\nprior_review_feedback=%t", taskRef, strings.TrimSpace(taskKind), strings.TrimSpace(runtimePhase), profile, priorReviewFeedback),
		Detail:  "preview only; not included in composed instruction; workers are not executed and Kanban state is not mutated",
	})
	return layers, nil
}

func promptPreviewPhaseResolution(phases map[string]promptPhaseYAML, profile string) (string, promptPhaseYAML) {
	config := phases[profile]
	if !promptPhaseConfigEmpty(config) {
		return profile, config
	}
	if profile == "implementation_rework" {
		implementation := phases["implementation"]
		if !promptPhaseConfigEmpty(implementation) {
			return "implementation", implementation
		}
	}
	return profile, promptPhaseYAML{}
}

func promptPhaseConfigEmpty(config promptPhaseYAML) bool {
	return strings.TrimSpace(config.Prompt) == "" && len(config.Skills) == 0 && strings.TrimSpace(config.ChildDraftTemplate) == ""
}

func promptPreviewHasCoreInstruction(runtimePhase string) bool {
	return runtimePhase == "implementation" || runtimePhase == "review"
}

func promptPreviewHasTicketInstruction(runtimePhase string) bool {
	return runtimePhase == "implementation" || runtimePhase == "review"
}

func coreSkillPhase(runtimePhase string, profile string) string {
	if profile == "parent_review" {
		return "parent_review"
	}
	if runtimePhase == "review" {
		return "review"
	}
	return "implementation"
}

func coreSkillDetail(runtimePhase string, profile string) string {
	switch {
	case profile == "parent_review":
		return "source=runtime.phases.parent_review.skill"
	case runtimePhase == "implementation" || runtimePhase == "review":
		return "source=runtime.phases." + coreSkillPhase(runtimePhase, profile) + ".skill"
	default:
		return "source=runtime phase command contract"
	}
}

func coreSkillForPromptPreview(config projectPromptYAML, runtimePhase string, profile string) string {
	if !promptPreviewHasCoreInstruction(runtimePhase) {
		return ""
	}
	phase := coreSkillPhase(runtimePhase, profile)
	rawSkill := config.Runtime.Phases[phase].Skill
	switch value := rawSkill.(type) {
	case string:
		return value
	case map[string]any, []any:
		return strings.TrimSpace(fmt.Sprintf("%v", value))
	default:
		if value == nil {
			return ""
		}
		return strings.TrimSpace(fmt.Sprintf("%v", value))
	}
}

func promptPhaseLayers(packagePath string, prefix string, templateKind string, profile string, config promptPhaseYAML) ([]promptLayerPreview, error) {
	layers := []promptLayerPreview{}
	if strings.TrimSpace(config.Prompt) != "" {
		layer, err := readPromptLayer(packagePath, prefix+"_prompt", config.Prompt)
		if err != nil {
			return nil, err
		}
		layer.Detail = "profile=" + profile
		layers = append(layers, layer)
	}
	for _, skill := range config.Skills {
		layer, err := readPromptLayer(packagePath, prefix+"_skill", skill)
		if err != nil {
			return nil, err
		}
		layer.Detail = "profile=" + profile
		layers = append(layers, layer)
	}
	if strings.TrimSpace(config.ChildDraftTemplate) != "" {
		layer, err := readPromptLayer(packagePath, templateKind, config.ChildDraftTemplate)
		if err != nil {
			return nil, err
		}
		layer.Detail = "profile=" + profile
		layers = append(layers, layer)
	}
	return layers, nil
}

func composedPromptPreview(layers []promptLayerPreview) string {
	sections := []string{}
	for _, layer := range layers {
		if layer.Kind == "task_runtime_data" {
			continue
		}
		sections = append(sections, fmt.Sprintf("## %s\n%s", layer.Title, strings.TrimRight(layer.Content, "\n")))
	}
	return strings.Join(sections, "\n\n")
}

func readPromptLayer(packagePath string, kind string, relativePath string) (promptLayerPreview, error) {
	path := filepath.Join(packagePath, filepath.FromSlash(relativePath))
	body, err := os.ReadFile(path)
	if err != nil {
		return promptLayerPreview{}, fmt.Errorf("read %s %s: %w", kind, relativePath, err)
	}
	return promptLayerPreview{
		Kind:    kind,
		Title:   relativePath,
		Path:    path,
		Content: string(body),
	}, nil
}

func runDoctorPrompts(args []string, stdout io.Writer, stderr io.Writer) int {
	flags := flag.NewFlagSet("a2o doctor prompts", flag.ContinueOnError)
	flags.SetOutput(stderr)
	packagePath := flags.String("package", "", "project package directory")
	configPath := flags.String("config", "", "project config file; defaults to project.yaml under --package")
	workspaceRoot := flags.String("workspace", ".", "workspace root used when discovering ./a2o-project or ./project-package")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if flags.NArg() != 0 {
		printUserFacingError(stderr, fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " ")))
		return 2
	}
	status := "ok"
	report := func(name string, ok bool, detail string, action string) {
		checkStatus := "ok"
		if !ok {
			checkStatus = "blocked"
			status = "blocked"
		}
		fmt.Fprintf(stdout, "prompt_doctor_check name=%s status=%s detail=%s action=%s\n", name, checkStatus, singleLine(detail), singleLine(action))
	}
	context, err := loadPromptCommandContext(*packagePath, *configPath, *workspaceRoot)
	if err != nil {
		report("project_package", false, err.Error(), "fix runtime.prompts paths, phase names, repoSlots, or childDraftTemplate placement")
		fmt.Fprintf(stdout, "prompt_doctor_status=%s\n", status)
		return 1
	}
	report("project_package", true, context.configPath, "none")
	prompts := context.config.Runtime.Prompts
	if strings.TrimSpace(prompts.System.File) != "" {
		report("project_system_prompt", true, prompts.System.File, "none")
	}
	phaseNames := make([]string, 0, len(prompts.Phases))
	for phase := range prompts.Phases {
		phaseNames = append(phaseNames, phase)
	}
	sort.Strings(phaseNames)
	for _, phase := range phaseNames {
		config := prompts.Phases[phase]
		detail := promptPhaseDoctorDetail(config)
		if detail == "" {
			detail = "empty phase prompt profile"
		}
		report("phase."+phase, true, detail, "none")
	}
	if _, hasRework := prompts.Phases["implementation_rework"]; !hasRework {
		if _, hasImplementation := prompts.Phases["implementation"]; hasImplementation {
			report("phase.implementation_rework", true, "fallback=implementation", "none")
		}
	}
	slotNames := make([]string, 0, len(prompts.RepoSlots))
	for slot := range prompts.RepoSlots {
		slotNames = append(slotNames, slot)
	}
	sort.Strings(slotNames)
	for _, slot := range slotNames {
		slotPhases := prompts.RepoSlots[slot].Phases
		names := make([]string, 0, len(slotPhases))
		for phase := range slotPhases {
			names = append(names, phase)
		}
		sort.Strings(names)
		report("repo_slot."+slot, true, "phases="+strings.Join(names, ","), "none")
	}
	fmt.Fprintf(stdout, "prompt_doctor_status=%s\n", status)
	if status != "ok" {
		return 1
	}
	return 0
}

func promptPhaseDoctorDetail(config promptPhaseYAML) string {
	parts := []string{}
	if strings.TrimSpace(config.Prompt) != "" {
		parts = append(parts, "prompt="+config.Prompt)
	}
	if len(config.Skills) > 0 {
		parts = append(parts, "skills="+strings.Join(config.Skills, ","))
	}
	if strings.TrimSpace(config.ChildDraftTemplate) != "" {
		parts = append(parts, "childDraftTemplate="+config.ChildDraftTemplate)
	}
	return strings.Join(parts, " ")
}
