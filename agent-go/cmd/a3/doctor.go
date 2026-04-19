package main

import (
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

var projectScriptContractA3EnvPattern = regexp.MustCompile(`A3_[A-Z0-9_]+`)

func runDoctor(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) int {
	flags := flag.NewFlagSet("a2o doctor", flag.ContinueOnError)
	flags.SetOutput(stderr)
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
		fmt.Fprintf(stdout, "doctor_check name=%s status=%s detail=%s action=%s\n", name, checkStatus, singleLine(detail), singleLine(action))
	}

	config, configPath, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		report("runtime_instance_config", false, err.Error(), "run a2o project bootstrap")
		fmt.Fprintf(stdout, "doctor_status=%s\n", status)
		return 1
	}
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", publicInstanceConfigPath(configPath))
	fmt.Fprintf(stdout, "compose_project=%s\n", effectiveConfig.ComposeProject)
	fmt.Fprintf(stdout, "kanban_volume=%s\n", kanbanDataVolumeName(effectiveConfig.ComposeProject))

	packageConfig, err := loadProjectPackageConfig(config.PackagePath)
	if err != nil {
		report("project_package", false, err.Error(), "fix project.yaml or rerun a2o project template")
	} else {
		report("project_package", true, "project.yaml schema_version="+packageConfig.SchemaVersion+" package="+packageConfig.PackageName, "none")
		checkExecutorConfig(packageConfig, report)
		checkProjectScriptContract(config.PackagePath, report)
		checkRequiredCommands(packageConfig, runner, report)
		checkRepoClean(config.PackagePath, packageConfig, runner, report)
	}

	agentPath := filepath.Join(config.WorkspaceRoot, hostAgentBinRelativePath)
	agentInstallAction := "run " + agentInstallCommand(agentPath)
	if info, err := os.Stat(agentPath); err != nil {
		report("agent_install", false, agentPath+" not found", agentInstallAction)
	} else if info.Mode().Perm()&0o111 == 0 {
		report("agent_install", false, agentPath+" is not executable", agentInstallAction)
	} else {
		report("agent_install", true, agentPath, "none")
	}

	if exists, err := dockerVolumeExists(runner, kanbanDataVolumeName(effectiveConfig.ComposeProject)); err != nil {
		report("kanban_volume", false, err.Error(), "check Docker daemon and compose project")
	} else if exists {
		report("kanban_volume", true, "reuse_existing volume="+kanbanDataVolumeName(effectiveConfig.ComposeProject)+" note=healthy_board_reuse", "none")
	} else {
		report("kanban_volume", true, "create_new "+kanbanDataVolumeName(effectiveConfig.ComposeProject), "none")
	}

	if output, err := runExternal(runner, "docker", append(composeArgs(effectiveConfig), "ps", "--status", "running", "-q", "soloboard")...); err != nil {
		report("kanban_service", false, err.Error(), "run a2o kanban up")
	} else if strings.TrimSpace(string(output)) == "" {
		report("kanban_service", false, "soloboard is not running", "run a2o kanban up")
	} else {
		report("kanban_service", true, kanbanPublicURL(effectiveConfig), "none")
	}

	if output, err := runExternal(runner, "docker", append(composeArgs(effectiveConfig), "ps", "--status", "running", "-q", effectiveConfig.RuntimeService)...); err != nil {
		report("runtime_container", false, err.Error(), "run a2o runtime up")
	} else if strings.TrimSpace(string(output)) == "" {
		report("runtime_container", false, "A2O runtime container is not running", "run a2o runtime up")
	} else {
		report("runtime_container", true, "A2O runtime container="+strings.TrimSpace(string(output)), "none")
	}

	if digest := runtimeImageDigest(config, runner); digest != "" {
		report("runtime_image_digest", true, digest, "pin this digest for release smoke")
	} else {
		report("runtime_image_digest", false, "digest unavailable", "pull or build the runtime image, then rerun a2o doctor")
	}

	fmt.Fprintf(stdout, "doctor_status=%s\n", status)
	if status != "ok" {
		return 1
	}
	return 0
}

func checkExecutorConfig(config projectPackageConfig, report func(string, bool, string, string)) {
	bins := executorCommandBins(config.Executor)
	if len(bins) == 0 {
		report("executor_config", false, "runtime.phases executor command is missing", "set runtime.phases.implementation.executor.command in project.yaml or regenerate with a2o project template")
		return
	}
	report("executor_config", true, "commands="+strings.Join(bins, ","), "none")
}

func checkRequiredCommands(config projectPackageConfig, runner commandRunner, report func(string, bool, string, string)) {
	required := append([]string{}, config.AgentRequiredBins...)
	required = append(required, executorCommandBins(config.Executor)...)
	sort.Strings(required)
	seen := map[string]bool{}
	for _, bin := range required {
		bin = strings.TrimSpace(bin)
		if bin == "" || seen[bin] {
			continue
		}
		seen[bin] = true
		if _, err := runner.Run("sh", "-lc", "command -v "+shellQuote(bin)); err != nil {
			report("agent_required_command."+bin, false, bin+" not found on host agent PATH", "install "+bin+" where a2o-agent runs or update project.yaml agent.required_bins/runtime.phases")
		} else {
			report("agent_required_command."+bin, true, bin+" found on host agent PATH", "none")
		}
	}
}

func checkProjectScriptContract(packagePath string, report func(string, bool, string, string)) {
	findings := []string{}
	err := filepath.WalkDir(packagePath, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		name := entry.Name()
		if entry.IsDir() {
			switch name {
			case ".git", ".work", "node_modules", "vendor", "target", "dist", "build":
				return filepath.SkipDir
			}
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() || info.Size() > 1024*1024 || !isProjectScriptContractScanTarget(packagePath, path, info.Mode()) {
			return nil
		}
		body, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		for _, violation := range projectScriptContractViolations(string(body)) {
			rel, _ := filepath.Rel(packagePath, path)
			findings = append(findings, rel+":"+violation)
		}
		return nil
	})
	if err != nil {
		report("project_script_contract", false, err.Error(), "inspect project package files")
		return
	}
	if len(findings) > 0 {
		sort.Strings(findings)
		report("project_script_contract", false, strings.Join(findings, ","), "use A2O_* worker env and worker request fields instead of internal runtime files")
		return
	}
	report("project_script_contract", true, "public A2O script contract only", "none")
}

func isProjectScriptContractScanTarget(packagePath string, path string, mode os.FileMode) bool {
	rel, err := filepath.Rel(packagePath, path)
	if err != nil {
		return false
	}
	parts := strings.Split(filepath.ToSlash(rel), "/")
	if len(parts) == 1 && isPackageAutomationFile(parts[0]) {
		return true
	}
	if len(parts) > 1 {
		switch parts[0] {
		case "commands", "inject", "scripts", "bin":
			return true
		}
	}
	if mode&0o111 != 0 {
		return true
	}
	switch strings.ToLower(filepath.Ext(path)) {
	case ".sh", ".bash", ".zsh", ".rb", ".py", ".js", ".mjs", ".cjs", ".ts", ".go", ".env", ".json", ".yml", ".yaml":
		return true
	default:
		return false
	}
}

func isPackageAutomationFile(name string) bool {
	switch name {
	case "project.yaml", "project.yml", "Taskfile.yml", "Taskfile.yaml", "Makefile", ".env", "package.json":
		return true
	default:
		return false
	}
}

func projectScriptContractViolations(text string) []string {
	violations := []string{}
	checks := []struct {
		label string
		match func(string) bool
	}{
		{"A3_*", func(value string) bool {
			return projectScriptContractA3EnvPattern.MatchString(value) || strings.Contains(value, "A3_")
		}},
		{".a3/workspace.json", func(value string) bool {
			return strings.Contains(value, ".a3/workspace.json") || (strings.Contains(value, ".a3") && strings.Contains(value, "workspace.json"))
		}},
		{".a3/slot.json", func(value string) bool {
			return strings.Contains(value, ".a3/slot.json") || (strings.Contains(value, ".a3") && strings.Contains(value, "slot.json"))
		}},
		{"launcher.json", func(value string) bool {
			return strings.Contains(value, "launcher.json") || (strings.Contains(value, "launcher") && strings.Contains(value, ".json"))
		}},
	}
	for _, check := range checks {
		if check.match(text) {
			violations = append(violations, check.label)
		}
	}
	return violations
}

func executorCommandBins(executor map[string]any) []string {
	profiles := []any{}
	if profile, ok := executor["default_profile"]; ok {
		profiles = append(profiles, profile)
	}
	if phaseProfiles, ok := executor["phase_profiles"].(map[string]any); ok {
		for _, profile := range phaseProfiles {
			profiles = append(profiles, profile)
		}
	}
	bins := []string{}
	for _, profile := range profiles {
		profileMap, ok := profile.(map[string]any)
		if !ok {
			continue
		}
		command, ok := profileMap["command"].([]any)
		if !ok || len(command) == 0 {
			continue
		}
		bins = append(bins, fmt.Sprint(command[0]))
	}
	return bins
}

func checkRepoClean(packagePath string, config projectPackageConfig, runner commandRunner, report func(string, bool, string, string)) {
	aliases := sortedProjectRepoAliases(config.Repos)
	for _, alias := range aliases {
		path := resolvePackagePath(packagePath, config.Repos[alias].Path)
		output, err := runner.Run("git", "-C", path, "status", "--porcelain", "--untracked-files=all")
		if err != nil {
			report("repo_clean."+alias, false, err.Error(), "check repo path in project.yaml")
			continue
		}
		changed := strings.TrimSpace(string(output))
		if changed != "" {
			report("repo_clean."+alias, false, changed, "commit, stash, or remove dirty files before running A2O")
			continue
		}
		report("repo_clean."+alias, true, path, "none")
	}
}

func runtimeImageDigest(config *runtimeInstanceConfig, runner commandRunner) string {
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	imageID, err := runExternal(runner, "docker", append(composeArgs(effectiveConfig), "images", "--quiet", effectiveConfig.RuntimeService)...)
	if err != nil {
		return ""
	}
	id := strings.TrimSpace(string(imageID))
	if id == "" {
		return ""
	}
	digest, err := runExternal(runner, "docker", "image", "inspect", id, "--format", "{{index .RepoDigests 0}}")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(digest))
}

func singleLine(value string) string {
	return strings.Join(strings.Fields(value), " ")
}
