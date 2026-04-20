package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

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
	fmt.Fprintln(stdout, "upgrade_check mode=check-only apply_supported=false")
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
		fmt.Fprintln(stdout, "upgrade_next 1 command=a2o runtime image-digest purpose=confirm configured, local latest, and running image digests")
		fmt.Fprintln(stdout, "upgrade_next 2 command=a2o runtime up --pull purpose=pull/start the configured runtime image after confirming the desired pin")
		fmt.Fprintln(stdout, "upgrade_next 3 command=a2o agent install --target auto --output "+shellQuote(filepath.Join(effectiveConfig.WorkspaceRoot, hostAgentBinRelativePath))+" purpose=refresh host a2o-agent from the runtime image")
		fmt.Fprintln(stdout, "upgrade_next 4 command=a2o doctor purpose=run release-readiness checks after upgrade")
		fmt.Fprintln(stdout, "upgrade_next 5 command=a2o runtime status purpose=confirm scheduler, runtime, kanban, image digest, and latest run status")
		return nil
	})
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
