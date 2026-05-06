package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

var executablePathFunc = os.Executable
var execUpgradeFinalizer = syscall.Exec

func runUpgrade(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "missing upgrade subcommand")
		printUsage(stderr)
		return 2
	}
	if isHelpArg(args[0]) {
		printUsage(stdout)
		return 0
	}
	switch args[0] {
	case "check":
		if err := runUpgradeCheck(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "apply":
		if err := runUpgradeApply(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "finalize":
		if err := runUpgradeFinalize(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	default:
		fmt.Fprintf(stderr, "unknown upgrade subcommand: %s\n", args[0])
		printUsage(stderr)
		return 2
	}
}

func runUpgradeCheck(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o upgrade check", flag.ContinueOnError)
	flags.SetOutput(stderr)
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	config, configPath, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	fmt.Fprintln(stdout, "upgrade_check mode=check-only apply_supported=true")
	fmt.Fprintf(stdout, "host_launcher_version=%s\n", version)
	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", publicInstanceConfigPath(configPath))
	fmt.Fprintf(stdout, "runtime_package=%s\n", effectiveConfig.PackagePath)
	fmt.Fprintf(stdout, "compose_project=%s\n", effectiveConfig.ComposeProject)
	fmt.Fprintf(stdout, "kanban_url=%s\n", kanbanPublicURL(effectiveConfig))
	printUpgradeRuntimeImagePackageStatus(effectiveConfig, stdout)

	return withComposeEnv(effectiveConfig, func() error {
		report := runtimeImageDigestReport(&effectiveConfig, runner)
		printRuntimeImageDigestReport(report, stdout)
		printUpgradeAgentStatus(effectiveConfig, stdout)
		printUpgradeDoctorStatus(runner, stdout, stderr)
		upgradeVersion := upgradeVersionFromImageReference(packagedRuntimeImageReferenceFunc())
		if upgradeVersion == "" && version != "" && version != "dev" {
			upgradeVersion = version
		}
		if upgradeVersion != "" {
			fmt.Fprintf(stdout, "upgrade_next 1 command=a2o upgrade apply %s purpose=apply host launcher, shared assets, runtime image, agent, and doctor checks\n", shellQuote(upgradeVersion))
			fmt.Fprintln(stdout, "upgrade_next 2 command=a2o runtime status purpose=confirm scheduler, runtime, kanban, image digest, and latest run status")
		} else {
			fmt.Fprintln(stdout, "upgrade_next 1 command=a2o runtime image-digest purpose=confirm configured, local latest, and running image digests")
			fmt.Fprintln(stdout, "upgrade_next 2 command=a2o runtime up --pull purpose=pull/start the configured runtime image after confirming the desired pin")
			fmt.Fprintln(stdout, "upgrade_next 3 command=a2o agent install --target auto --output "+shellQuote(filepath.Join(effectiveConfig.WorkspaceRoot, hostAgentBinRelativePath))+" purpose=refresh host a2o-agent from the runtime image")
			fmt.Fprintln(stdout, "upgrade_next 4 command=a2o doctor purpose=run release-readiness checks after upgrade")
			fmt.Fprintln(stdout, "upgrade_next 5 command=a2o runtime status purpose=confirm scheduler, runtime, kanban, image digest, and latest run status")
		}
		return nil
	})
}

func runUpgradeApply(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o upgrade apply", flag.ContinueOnError)
	flags.SetOutput(stderr)
	image := flags.String("image", "", "runtime image reference to install instead of ghcr.io/wamukat/a2o-engine:<version>")
	installRoot := flags.String("install-root", "", "host install root containing bin/ and share/; defaults to the current launcher root")
	dryRun := flags.Bool("dry-run", false, "print the finalizer plan without applying the upgrade")
	flagArgs, targetVersion, err := splitUpgradeApplyArgs(args)
	if err != nil {
		return err
	}
	if err := flags.Parse(flagArgs); err != nil {
		return err
	}
	targetVersion = strings.TrimSpace(targetVersion)
	if targetVersion == "" {
		return fmt.Errorf("usage: a2o upgrade apply <version>")
	}
	targetImage := strings.TrimSpace(*image)
	if targetImage == "" {
		targetImage = "ghcr.io/wamukat/a2o-engine:" + targetVersion
	}

	config, configPath, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	registryPath := filepath.Join(effectiveConfig.WorkspaceRoot, projectRegistryRelativePath)
	if _, err := os.Stat(registryPath); err == nil {
		return fmt.Errorf("a2o upgrade apply does not support project registry workspaces yet: %s; pause all projects and use the manual upgrade sequence for now", registryPath)
	} else if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("inspect project registry: %w", err)
	}
	paths := schedulerPaths(effectiveConfig)
	if pid, running, err := readRunningScheduler(paths.PIDFile, runner); err != nil {
		return err
	} else if running {
		return fmt.Errorf("scheduler is running pid=%d; pause it before upgrade: a2o runtime pause", pid)
	}

	roots, currentBinDir, err := upgradeInstallRoots(effectiveConfig, *installRoot)
	if err != nil {
		return err
	}
	plan := upgradeApplyPlan{
		Version:       targetVersion,
		Image:         targetImage,
		WorkspaceRoot: effectiveConfig.WorkspaceRoot,
		ConfigPath:    configPath,
		BackupPath:    configPath + ".upgrade-backup",
		AgentOutput:   filepath.Join(effectiveConfig.WorkspaceRoot, hostAgentBinRelativePath),
		InstallRoots:  roots,
		LauncherPath:  filepath.Join(currentBinDir, "a2o"),
	}
	script := upgradeFinalizerScript(plan)

	fmt.Fprintf(stdout, "upgrade_apply mode=handoff version=%s image=%s config=%s\n", targetVersion, targetImage, publicInstanceConfigPath(configPath))
	for index, root := range roots {
		fmt.Fprintf(stdout, "upgrade_install_root index=%d path=%s\n", index+1, root)
	}
	if *dryRun {
		fmt.Fprintln(stdout, "upgrade_finalizer_script_begin")
		fmt.Fprint(stdout, script)
		if !strings.HasSuffix(script, "\n") {
			fmt.Fprintln(stdout)
		}
		fmt.Fprintln(stdout, "upgrade_finalizer_script_end")
		return nil
	}
	return execUpgradeFinalizer("/bin/sh", []string{"sh", "-c", script}, os.Environ())
}

func splitUpgradeApplyArgs(args []string) ([]string, string, error) {
	flagArgs := []string{}
	version := ""
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "--dry-run":
			flagArgs = append(flagArgs, arg)
		case arg == "--image" || arg == "--install-root":
			if i+1 >= len(args) {
				return nil, "", fmt.Errorf("%s requires a value", arg)
			}
			flagArgs = append(flagArgs, arg, args[i+1])
			i++
		case strings.HasPrefix(arg, "--image=") || strings.HasPrefix(arg, "--install-root="):
			flagArgs = append(flagArgs, arg)
		case strings.HasPrefix(arg, "-"):
			flagArgs = append(flagArgs, arg)
		default:
			if version != "" {
				return nil, "", fmt.Errorf("unexpected arguments: %s", strings.Join(args[i:], " "))
			}
			version = arg
		}
	}
	return flagArgs, version, nil
}

type upgradeApplyPlan struct {
	Version       string
	Image         string
	WorkspaceRoot string
	ConfigPath    string
	BackupPath    string
	AgentOutput   string
	InstallRoots  []string
	LauncherPath  string
}

func upgradeInstallRoots(config runtimeInstanceConfig, explicitInstallRoot string) ([]string, string, error) {
	executable, err := executablePathFunc()
	if err != nil {
		return nil, "", fmt.Errorf("resolve current executable: %w", err)
	}
	binDir := filepath.Dir(executable)
	currentRoot := filepath.Dir(binDir)
	if strings.TrimSpace(explicitInstallRoot) != "" {
		currentRoot, err = filepath.Abs(strings.TrimSpace(explicitInstallRoot))
		if err != nil {
			return nil, "", fmt.Errorf("resolve install root: %w", err)
		}
		binDir = filepath.Join(currentRoot, "bin")
	}
	projectRoot := filepath.Join(config.WorkspaceRoot, ".work", "a2o")
	return uniquePaths([]string{currentRoot, projectRoot}), binDir, nil
}

func uniquePaths(paths []string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, path := range paths {
		clean := filepath.Clean(strings.TrimSpace(path))
		if clean == "." || clean == "" || seen[clean] {
			continue
		}
		seen[clean] = true
		out = append(out, clean)
	}
	return out
}

func upgradeFinalizerScript(plan upgradeApplyPlan) string {
	lines := []string{
		"set -eu",
		"echo " + shellQuote("upgrade_step step=docker_pull image="+plan.Image),
		"docker pull " + shellQuote(plan.Image),
	}
	for _, root := range plan.InstallRoots {
		lines = append(lines,
			"mkdir -p "+shellQuote(filepath.Join(root, "bin"))+" "+shellQuote(filepath.Join(root, "share")),
			"echo "+shellQuote("upgrade_step step=host_install root="+root+" image="+plan.Image),
			"docker run --rm -v "+shellQuote(root+":/install")+" "+shellQuote(plan.Image)+" a2o host install --output-dir /install/bin --share-dir /install/share/a2o --runtime-image "+shellQuote(plan.Image),
		)
	}
	lines = append(lines,
		"cd "+shellQuote(plan.WorkspaceRoot),
		"launcher="+shellQuote(plan.LauncherPath),
		"if [ ! -x \"$launcher\" ]; then launcher="+shellQuote(filepath.Join(plan.WorkspaceRoot, ".work", "a2o", "bin", "a2o"))+"; fi",
		"echo "+shellQuote("upgrade_step step=finalize image="+plan.Image),
		"exec \"$launcher\" upgrade finalize --version "+shellQuote(plan.Version)+" --image "+shellQuote(plan.Image)+" --config-path "+shellQuote(plan.ConfigPath)+" --backup-path "+shellQuote(plan.BackupPath)+" --agent-output "+shellQuote(plan.AgentOutput),
	)
	return strings.Join(lines, "\n") + "\n"
}

func runUpgradeFinalize(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o upgrade finalize", flag.ContinueOnError)
	flags.SetOutput(stderr)
	targetVersion := flags.String("version", "", "target upgrade version")
	targetImage := flags.String("image", "", "target runtime image")
	configPath := flags.String("config-path", "", "runtime instance config path")
	backupPath := flags.String("backup-path", "", "runtime instance config backup path")
	agentOutput := flags.String("agent-output", "", "host a2o-agent output path")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	if strings.TrimSpace(*targetVersion) == "" || strings.TrimSpace(*targetImage) == "" || strings.TrimSpace(*configPath) == "" || strings.TrimSpace(*backupPath) == "" {
		return fmt.Errorf("usage: a2o upgrade finalize --version VERSION --image IMAGE --config-path PATH --backup-path PATH")
	}
	config, err := readInstanceConfig(*configPath)
	if err != nil {
		return err
	}
	original, err := os.ReadFile(*configPath)
	if err != nil {
		return fmt.Errorf("read runtime instance config for backup: %w", err)
	}
	if err := os.WriteFile(*backupPath, original, 0o644); err != nil {
		return fmt.Errorf("write runtime instance config backup: %w", err)
	}
	config.RuntimeImage = strings.TrimSpace(*targetImage)
	if err := writeInstanceConfigPath(*configPath, *config); err != nil {
		return err
	}
	restore := func(cause error) error {
		_ = os.WriteFile(*configPath, original, 0o644)
		return fmt.Errorf("%w; runtime instance config restored from %s", cause, *backupPath)
	}
	afterRuntimeRestartFailure := func(cause error) error {
		return fmt.Errorf("%w; runtime instance config remains on %s because the runtime may already be running the target image; backup=%s recovery=inspect a2o runtime status and rerun a2o upgrade apply or manually restore the previous image", cause, strings.TrimSpace(*targetImage), *backupPath)
	}
	if err := runRuntimeUp([]string{"--pull"}, runner, stdout, stderr); err != nil {
		return restore(fmt.Errorf("upgrade runtime up failed: %w", err))
	}
	outputPath := strings.TrimSpace(*agentOutput)
	if outputPath == "" {
		outputPath = filepath.Join(config.WorkspaceRoot, hostAgentBinRelativePath)
	}
	if code := runAgent([]string{"install", "--target", "auto", "--output", outputPath}, runner, stdout, stderr); code != 0 {
		return afterRuntimeRestartFailure(fmt.Errorf("upgrade agent install failed exit_code=%d", code))
	}
	if code := runDoctor([]string{}, runner, stdout, stderr); code != 0 {
		return afterRuntimeRestartFailure(fmt.Errorf("upgrade doctor failed exit_code=%d", code))
	}
	fmt.Fprintf(stdout, "upgrade_complete version=%s doctor_status=ok\n", strings.TrimSpace(*targetVersion))
	return nil
}

func writeInstanceConfigPath(path string, config runtimeInstanceConfig) error {
	body, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return fmt.Errorf("encode instance config: %w", err)
	}
	body = append(body, '\n')
	if err := os.WriteFile(path, body, 0o644); err != nil {
		return fmt.Errorf("write instance config: %w", err)
	}
	return nil
}

func upgradeVersionFromImageReference(ref string) string {
	ref = strings.TrimSpace(ref)
	if ref == "" || strings.Contains(ref, "@sha256:") {
		return ""
	}
	index := strings.LastIndex(ref, ":")
	if index < 0 || index == len(ref)-1 {
		return ""
	}
	tag := ref[index+1:]
	if tag == "latest" {
		return ""
	}
	return tag
}

func printUpgradeRuntimeImagePackageStatus(config runtimeInstanceConfig, stdout io.Writer) {
	instanceRef := strings.TrimSpace(config.RuntimeImage)
	packagedRef := strings.TrimSpace(packagedRuntimeImageReferenceFunc())
	status := "unknown"
	action := "none"
	switch {
	case packagedRef == "":
		action = "install a release launcher with a packaged runtime image reference"
	case instanceRef == "":
		status = "not_pinned"
		action = "run a2o project bootstrap to write the packaged runtime image into the instance config"
	case runtimeImageRefIdentity(instanceRef) == runtimeImageRefIdentity(packagedRef):
		status = "current"
	default:
		status = "stale"
		action = "run a2o project bootstrap, then a2o runtime up --pull after confirming the desired pin"
	}
	fmt.Fprintf(stdout, "runtime_image_instance_ref=%s\n", valueOrUnavailable(instanceRef))
	fmt.Fprintf(stdout, "runtime_image_packaged_ref=%s\n", valueOrUnavailable(packagedRef))
	fmt.Fprintf(stdout, "runtime_image_package_status=%s action=%s\n", status, action)
}

func printUpgradeAgentStatus(config runtimeInstanceConfig, stdout io.Writer) {
	agentPath := filepath.Join(config.WorkspaceRoot, hostAgentBinRelativePath)
	if info, err := os.Stat(agentPath); err != nil {
		fmt.Fprintf(stdout, "upgrade_agent status=missing path=%s action=%s\n", agentPath, agentInstallCommand(agentPath))
	} else if info.Mode().Perm()&0o111 == 0 {
		fmt.Fprintf(stdout, "upgrade_agent status=not_executable path=%s action=%s\n", agentPath, agentInstallCommand(agentPath))
	} else {
		fmt.Fprintf(stdout, "upgrade_agent status=installed path=%s action=none\n", agentPath)
	}
}

func printUpgradeDoctorStatus(runner commandRunner, stdout io.Writer, stderr io.Writer) {
	fmt.Fprintln(stdout, "upgrade_doctor_begin")
	code := runDoctor([]string{}, runner, stdout, stderr)
	status := "blocked"
	if code == 0 {
		status = "ok"
	}
	fmt.Fprintf(stdout, "upgrade_doctor_status=%s exit_code=%d\n", status, code)
}

func runtimeImageRefIdentity(ref string) string {
	ref = strings.TrimSpace(ref)
	if digest := digestIdentity(ref); digest != "" {
		return digest
	}
	return ref
}
