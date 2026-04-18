package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

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
		report("runtime_instance_config", false, err.Error(), "run a2o project bootstrap --package DIR")
		fmt.Fprintf(stdout, "doctor_status=%s\n", status)
		return 1
	}
	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", configPath)
	fmt.Fprintf(stdout, "compose_project=%s\n", config.ComposeProject)
	fmt.Fprintf(stdout, "kanban_volume=%s\n", kanbanDataVolumeName(config.ComposeProject))

	packageConfig, err := loadProjectPackageConfig(config.PackagePath)
	if err != nil {
		report("project_package", false, err.Error(), "fix project.yaml or rerun a2o project template")
	} else {
		report("project_package", true, "project.yaml schema_version="+packageConfig.SchemaVersion+" package="+packageConfig.PackageName, "none")
		checkRequiredCommands(packageConfig, runner, report)
		checkRepoClean(config.PackagePath, packageConfig, runner, report)
	}

	agentPath := filepath.Join(config.WorkspaceRoot, hostAgentBinRelativePath)
	if info, err := os.Stat(agentPath); err != nil {
		report("agent_install", false, agentPath+" not found", "run a2o agent install --target auto --output ./"+filepath.ToSlash(hostAgentBinRelativePath))
	} else if info.Mode().Perm()&0o111 == 0 {
		report("agent_install", false, agentPath+" is not executable", "rerun a2o agent install")
	} else {
		report("agent_install", true, agentPath, "none")
	}

	if exists, err := dockerVolumeExists(runner, kanbanDataVolumeName(config.ComposeProject)); err != nil {
		report("kanban_volume", false, err.Error(), "check Docker daemon and compose project")
	} else if exists {
		report("kanban_volume", true, "reuse_existing "+kanbanDataVolumeName(config.ComposeProject), "backup before reset; use a2o kanban up --fresh-board to guard against reuse")
	} else {
		report("kanban_volume", true, "create_new "+kanbanDataVolumeName(config.ComposeProject), "none")
	}

	if output, err := runExternal(runner, "docker", append(composeArgs(*config), "ps", "--status", "running", "-q", "soloboard")...); err != nil {
		report("kanban_service", false, err.Error(), "run a2o kanban up")
	} else if strings.TrimSpace(string(output)) == "" {
		report("kanban_service", false, "soloboard is not running", "run a2o kanban up")
	} else {
		report("kanban_service", true, kanbanPublicURL(*config), "none")
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
			report("agent_required_command."+bin, false, bin+" not found on host agent PATH", "install "+bin+" where a2o-agent runs or update project.yaml agent.required_bins/runtime.executor")
		} else {
			report("agent_required_command."+bin, true, bin+" found on host agent PATH", "none")
		}
	}
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
	imageID, err := runExternal(runner, "docker", append(composeArgs(*config), "images", "--quiet", config.RuntimeService)...)
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
