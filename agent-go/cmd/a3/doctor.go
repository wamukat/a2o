package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
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

	checkDockerCredentialHelpers(report)

	packageConfig, err := loadProjectPackageConfig(config.PackagePath)
	if err != nil {
		report("project_package", false, err.Error(), "fix project.yaml or rerun a2o project template")
	} else {
		report("project_package", true, "project.yaml schema_version="+packageConfig.SchemaVersion+" package="+packageConfig.PackageName, "none")
		checkExecutorConfig(packageConfig, report)
		checkProjectScriptContract(config.PackagePath, report)
		checkProjectFixtureReferences(config.PackagePath, filepath.Join(config.PackagePath, "project.yaml"), false, func(name string, severity lintSeverity, detail string, action string) {
			report(name, severity != lintBlocked, detail, action)
		})
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

type dockerCredentialConfig struct {
	CredsStore  string            `json:"credsStore"`
	CredHelpers map[string]string `json:"credHelpers"`
}

func checkDockerCredentialHelpers(report func(string, bool, string, string)) {
	configPath, err := dockerConfigPath()
	if err != nil {
		report("docker_credential_helpers", false, err.Error(), "set DOCKER_CONFIG to a readable Docker config directory or fix HOME")
		return
	}
	body, err := os.ReadFile(configPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			report("docker_credential_helpers", true, "config_not_found path="+configPath, "none")
			return
		}
		report("docker_credential_helpers", false, err.Error(), "fix Docker config permissions or set DOCKER_CONFIG to a readable directory")
		return
	}
	var config dockerCredentialConfig
	if err := json.Unmarshal(body, &config); err != nil {
		report("docker_credential_helpers", false, "invalid Docker config JSON path="+configPath+" error="+err.Error(), "fix Docker config JSON or set DOCKER_CONFIG to a clean directory")
		return
	}

	helpers := []string{}
	if strings.TrimSpace(config.CredsStore) != "" {
		helpers = append(helpers, "credsStore="+strings.TrimSpace(config.CredsStore))
	}
	for registry, helper := range config.CredHelpers {
		helper = strings.TrimSpace(helper)
		if helper == "" {
			continue
		}
		helpers = append(helpers, "credHelpers["+registry+"]="+helper)
	}
	sort.Strings(helpers)
	if len(helpers) == 0 {
		report("docker_credential_helpers", true, "no credential helper configured path="+configPath, "none")
		return
	}

	missing := []string{}
	for _, helper := range helpers {
		name := helper[strings.LastIndex(helper, "=")+1:]
		binary := dockerCredentialHelperBinary(name)
		if _, err := exec.LookPath(binary); err != nil {
			missing = append(missing, helper+" binary="+binary)
		}
	}
	if len(missing) > 0 {
		report(
			"docker_credential_helpers",
			false,
			"path="+configPath+" missing="+strings.Join(missing, ","),
			`fix Docker config credsStore/credHelpers or run with temporary DOCKER_CONFIG containing {"auths":{}}`,
		)
		return
	}
	report("docker_credential_helpers", true, "path="+configPath+" helpers="+strings.Join(helpers, ","), "none")
}

func dockerConfigPath() (string, error) {
	if value := strings.TrimSpace(os.Getenv("DOCKER_CONFIG")); value != "" {
		return filepath.Join(value, "config.json"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".docker", "config.json"), nil
}

func dockerCredentialHelperBinary(helper string) string {
	helper = strings.TrimSpace(helper)
	if strings.HasPrefix(helper, "docker-credential-") {
		return helper
	}
	return "docker-credential-" + helper
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
		report("project_script_contract", false, strings.Join(findings, ","), projectScriptContractAction(findings))
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
	if len(parts) == 1 {
		return isPackageRootContractScanTarget(parts[0])
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
	return false
}

func isPackageRootContractScanTarget(name string) bool {
	lower := strings.ToLower(name)
	if lower == "readme" || strings.HasPrefix(lower, "readme.") || lower == "license" || strings.HasPrefix(lower, "license.") || lower == "changelog" || strings.HasPrefix(lower, "changelog.") {
		return false
	}
	switch strings.ToLower(filepath.Ext(name)) {
	case ".md", ".markdown", ".txt", ".rst", ".adoc":
		return false
	default:
		return true
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
		{".a2o/workspace.json", func(value string) bool {
			return strings.Contains(value, ".a2o/workspace.json") || (strings.Contains(value, ".a2o") && strings.Contains(value, "workspace.json"))
		}},
		{".a2o/slot.json", func(value string) bool {
			return strings.Contains(value, ".a2o/slot.json") || (strings.Contains(value, ".a2o") && strings.Contains(value, "slot.json"))
		}},
		{".a2o/worker-request.json", func(value string) bool {
			return strings.Contains(value, ".a2o/worker-request.json") || (strings.Contains(value, ".a2o") && strings.Contains(value, "worker-request.json"))
		}},
		{".a2o/worker-result.json", func(value string) bool {
			return strings.Contains(value, ".a2o/worker-result.json") || (strings.Contains(value, ".a2o") && strings.Contains(value, "worker-result.json"))
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

func projectScriptContractAction(findings []string) string {
	actions := []string{}
	if findingsContain(findings, "A3_*") {
		actions = append(actions, "replace A3_* names with A2O_* public env such as A2O_WORKER_REQUEST_PATH, A2O_WORKER_RESULT_PATH, A2O_WORKSPACE_ROOT, and A2O_ROOT_DIR")
	}
	if findingsContain(findings, ".a3/workspace.json") || findingsContain(findings, ".a2o/workspace.json") || findingsContain(findings, ".a3/slot.json") || findingsContain(findings, ".a2o/slot.json") || findingsContain(findings, ".a2o/worker-request.json") || findingsContain(findings, ".a2o/worker-result.json") {
		actions = append(actions, "replace private .a2o/.a3 metadata reads with the JSON at A2O_WORKER_REQUEST_PATH; use slot_paths for repo paths, scope_snapshot.verification_scope for target slots, and phase_runtime for task_kind/repo_scope/phase policy")
	}
	if findingsContain(findings, "launcher.json") {
		actions = append(actions, "remove launcher.json dependencies; configure runtime.phases.*.executor.command in project.yaml and let A2O generate launcher config")
	}
	if len(actions) == 0 {
		return "use the public worker request contract documented in docs/en/dev/55-project-script-contract.md"
	}
	actions = append(actions, "see docs/en/dev/55-project-script-contract.md")
	return strings.Join(actions, "; ")
}

func findingsContain(findings []string, marker string) bool {
	for _, finding := range findings {
		if strings.Contains(finding, marker) {
			return true
		}
	}
	return false
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

func imageDigestForReference(reference string, runner commandRunner) string {
	if strings.TrimSpace(reference) == "" {
		return ""
	}
	digest, err := runExternal(runner, "docker", "image", "inspect", reference, "--format", "{{index .RepoDigests 0}}")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(digest))
}

func runningRuntimeImageDigest(config runtimeInstanceConfig, runner commandRunner) (string, string, string) {
	containerOutput, err := runExternal(runner, "docker", append(composeArgs(config), "ps", "--status", "running", "-q", config.RuntimeService)...)
	if err != nil {
		return "", "", ""
	}
	containerID := strings.TrimSpace(string(containerOutput))
	if containerID == "" {
		return "", "", ""
	}
	imageOutput, err := runExternal(runner, "docker", "inspect", containerID, "--format", "{{.Image}}")
	if err != nil {
		return containerID, "", ""
	}
	imageID := strings.TrimSpace(string(imageOutput))
	return containerID, imageID, imageDigestForReference(imageID, runner)
}

func latestRuntimeImageReference(reference string) string {
	base := strings.TrimSpace(reference)
	if base == "" {
		return ""
	}
	if digestIndex := strings.Index(base, "@"); digestIndex >= 0 {
		base = base[:digestIndex]
	}
	lastSlash := strings.LastIndex(base, "/")
	lastColon := strings.LastIndex(base, ":")
	if lastColon > lastSlash {
		base = base[:lastColon]
	}
	if base == "" {
		return ""
	}
	return base + ":latest"
}

func singleLine(value string) string {
	return strings.Join(strings.Fields(value), " ")
}
