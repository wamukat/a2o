package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
)

func runRuntimeImageDigest(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime image-digest", flag.ContinueOnError)
	flags.SetOutput(stderr)
	projectKey := flags.String("project", "", "runtime project key")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	context, _, err := loadProjectRuntimeContextForCommand(*projectKey, true)
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(context.Config, "", "", "")
	return withComposeEnv(effectiveConfig, func() error {
		report := runtimeImageDigestReport(&effectiveConfig, runner)
		printRuntimeImageDigestReport(report, stdout)
		return nil
	})
}

func printRuntimeServiceStatus(config runtimeInstanceConfig, runner commandRunner, stdout io.Writer) {
	for _, check := range []struct {
		name    string
		service string
	}{
		{name: "runtime_container", service: config.RuntimeService},
		{name: "kanban_service", service: "kanbalone"},
	} {
		if check.name == "kanban_service" && isExternalKanban(config) {
			if err := checkExternalKanbanHealth(kanbanPublicURL(config)); err != nil {
				fmt.Fprintf(stdout, "runtime_status_check name=kanban_external status=blocked detail=%s\n", singleLine(err.Error()))
				continue
			}
			fmt.Fprintf(stdout, "runtime_status_check name=kanban_external status=ok url=%s runtime_url=%s\n", kanbanPublicURL(config), kanbanRuntimeURL(config))
			continue
		}
		output, err := runExternal(runner, "docker", append(composeArgs(config), "ps", "--status", "running", "-q", check.service)...)
		if err != nil {
			fmt.Fprintf(stdout, "runtime_status_check name=%s status=blocked detail=%s\n", check.name, singleLine(err.Error()))
			continue
		}
		containerID := strings.TrimSpace(string(output))
		if containerID == "" {
			fmt.Fprintf(stdout, "runtime_status_check name=%s status=stopped action=run a2o runtime up%s\n", check.name, runtimeProjectCommandArg(config.ProjectKey, config.MultiProjectMode))
			continue
		}
		fmt.Fprintf(stdout, "runtime_status_check name=%s status=running container=%s\n", check.name, containerID)
	}
}

func printRuntimeImageStatus(config *runtimeInstanceConfig, runner commandRunner, stdout io.Writer) {
	report := runtimeImageDigestReport(config, runner)
	if report.ConfiguredDigest != "" {
		printRuntimeImageDigestReport(report, stdout)
		return
	}
	fmt.Fprintln(stdout, "runtime_image_digest=unavailable action=pull or build runtime image")
}

type runtimeImageReport struct {
	ConfiguredRef      string
	ConfiguredDigest   string
	ConfiguredImageID  string
	LocalLatestRef     string
	LocalLatestDigest  string
	LocalLatestImageID string
	RunningContainer   string
	RunningImageID     string
	RunningDigest      string
	ProjectKey         string
	MultiProjectMode   bool
}

func runtimeImageDigestReport(config *runtimeInstanceConfig, runner commandRunner) runtimeImageReport {
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	configuredRef := runtimeImageReference(config)
	configuredIdentity := runtimeImageIdentity(&effectiveConfig, runner)
	report := runtimeImageReport{
		ConfiguredRef:     configuredRef,
		ConfiguredDigest:  configuredIdentity.Digest,
		ConfiguredImageID: configuredIdentity.ImageID,
		LocalLatestRef:    latestRuntimeImageReference(configuredRef),
		ProjectKey:        effectiveConfig.ProjectKey,
		MultiProjectMode:  effectiveConfig.MultiProjectMode,
	}
	if report.LocalLatestRef != "" {
		report.LocalLatestDigest = imageDigestForReference(report.LocalLatestRef, runner)
		report.LocalLatestImageID = imageIDForReference(report.LocalLatestRef, runner)
	}
	report.RunningContainer, report.RunningImageID, report.RunningDigest = runningRuntimeImageDigest(effectiveConfig, runner)
	return report
}

func printRuntimeImageDigestReport(report runtimeImageReport, stdout io.Writer) {
	fmt.Fprintf(stdout, "runtime_image_digest=%s\n", valueOrUnavailable(report.ConfiguredDigest))
	fmt.Fprintf(stdout, "runtime_image_pinned_ref=%s\n", valueOrUnavailable(report.ConfiguredRef))
	fmt.Fprintf(stdout, "runtime_image_pinned_digest=%s\n", valueOrUnavailable(report.ConfiguredDigest))
	fmt.Fprintf(stdout, "runtime_image_pinned_image_id=%s\n", valueOrUnavailable(report.ConfiguredImageID))
	fmt.Fprintf(stdout, "runtime_image_local_latest_ref=%s\n", valueOrUnavailable(report.LocalLatestRef))
	fmt.Fprintf(stdout, "runtime_image_local_latest_digest=%s\n", valueOrUnavailable(report.LocalLatestDigest))
	fmt.Fprintf(stdout, "runtime_image_local_latest_image_id=%s\n", valueOrUnavailable(report.LocalLatestImageID))
	if report.RunningContainer == "" {
		fmt.Fprintln(stdout, "runtime_image_running_container=unavailable")
	} else {
		fmt.Fprintf(stdout, "runtime_image_running_container=%s image_id=%s digest=%s\n", report.RunningContainer, valueOrUnavailable(report.RunningImageID), valueOrUnavailable(report.RunningDigest))
	}
	latestStatus := runtimeImageComparisonStatus(report.ConfiguredDigest, report.LocalLatestDigest, report.ConfiguredImageID, report.LocalLatestImageID)
	runningStatus := runtimeImageComparisonStatus(report.ConfiguredDigest, report.RunningDigest, report.ConfiguredImageID, report.RunningImageID)
	fmt.Fprintf(stdout, "runtime_image_latest_status=%s action=%s\n", latestStatus, runtimeImageLatestAction(latestStatus, report.LocalLatestRef, report))
	fmt.Fprintf(stdout, "runtime_image_running_status=%s action=%s\n", runningStatus, runtimeImageRunningAction(runningStatus, report))
}

func runtimeImageComparisonStatus(expected string, actual string, expectedImageID string, actualImageID string) string {
	expectedDigest := digestIdentity(expected)
	actualDigest := digestIdentity(actual)
	if expectedDigest != "" && actualDigest != "" {
		if expectedDigest == actualDigest {
			return "current"
		}
		return "mismatch"
	}
	expectedID := imageIDIdentity(expectedImageID)
	actualID := imageIDIdentity(actualImageID)
	if expectedDigest == "" && actualDigest == "" && expectedID != "" && actualID != "" {
		if expectedID == actualID {
			return "current"
		}
		return "mismatch"
	}
	return "unknown"
}

func imageIDIdentity(imageID string) string {
	return strings.TrimPrefix(strings.TrimSpace(imageID), "sha256:")
}

func runtimeImageLatestAction(status string, latestRef string, report runtimeImageReport) string {
	imageDigestCommand := "a2o runtime image-digest" + runtimeProjectCommandArg(report.ProjectKey, report.MultiProjectMode)
	switch status {
	case "current":
		return "none"
	case "mismatch":
		return "validate local latest, then update the package runtime image pin if you want this version"
	default:
		if latestRef == "" {
			return "configure A2O_RUNTIME_IMAGE, pull or inspect the configured runtime image, then rerun " + imageDigestCommand
		}
		return "pull " + latestRef + " or inspect the configured runtime image, then rerun " + imageDigestCommand
	}
}

func runtimeImageRunningAction(status string, report runtimeImageReport) string {
	runtimeUpCommand := "a2o runtime up" + runtimeProjectCommandArg(report.ProjectKey, report.MultiProjectMode)
	runtimeStatusCommand := "a2o runtime status" + runtimeProjectCommandArg(report.ProjectKey, report.MultiProjectMode)
	switch status {
	case "current":
		return "none"
	case "mismatch":
		return "restart runtime with " + runtimeUpCommand + " after confirming the desired pinned digest"
	default:
		return "run " + runtimeUpCommand + ", then rerun " + runtimeStatusCommand
	}
}

func digestIdentity(reference string) string {
	parts := strings.SplitN(strings.TrimSpace(reference), "@", 2)
	if len(parts) == 2 {
		return parts[1]
	}
	return ""
}

func valueOrUnavailable(value string) string {
	if strings.TrimSpace(value) == "" {
		return "unavailable"
	}
	return value
}
