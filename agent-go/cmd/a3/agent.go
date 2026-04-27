package main

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

func runAgent(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "missing agent subcommand")
		printUsage(stderr)
		return 2
	}
	if isHelpArg(args[0]) {
		printUsage(stdout)
		return 0
	}

	switch args[0] {
	case "target":
		target, err := detectHostTarget()
		if err != nil {
			printUserFacingError(stderr, err)
			return 2
		}
		fmt.Fprintln(stdout, target)
		return 0
	case "install":
		if err := runAgentInstall(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	default:
		fmt.Fprintf(stderr, "unknown agent subcommand: %s\n", args[0])
		printUsage(stderr)
		return 2
	}
}

func runAgentInstall(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o agent install", flag.ContinueOnError)
	flags.SetOutput(stderr)

	target := flags.String("target", "auto", "agent package target, or auto")
	output := flags.String("output", "", "host output path for the exported a2o-agent binary")
	packageDir := flags.String("package-dir", "", "host package directory for direct agent install")
	packageSource := flags.String("package-source", "auto", "agent package source: auto, package-dir, or runtime-image")
	composeProject := flags.String("compose-project", "", "docker compose project name")
	composeFile := flags.String("compose-file", "", "docker compose file")
	runtimeService := flags.String("runtime-service", "", "docker compose runtime service name")
	runtimeOutput := flags.String("runtime-output", "/tmp/a2o-agent-export", "temporary output path inside the runtime container")
	build := flags.Bool("build", false, "build the runtime image before exporting the agent")

	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	resolvedTarget := strings.TrimSpace(*target)
	if resolvedTarget == "" || resolvedTarget == "auto" {
		detected, err := detectHostTarget()
		if err != nil {
			return err
		}
		resolvedTarget = detected
	}

	resolution, err := resolveAgentPackageInstallSource(*packageSource, *packageDir)
	if err != nil {
		return err
	}

	instanceConfig, _, instanceConfigErr := loadInstanceConfigFromWorkingTree()
	config := runtimeInstanceConfig{}
	if instanceConfig != nil {
		config = *instanceConfig
	}
	config = applyAgentInstallOverrides(config, *composeProject, *composeFile, *runtimeService)

	outputValue := strings.TrimSpace(*output)
	if outputValue == "" {
		if strings.TrimSpace(config.WorkspaceRoot) == "" {
			return errors.New("--output is required when no runtime instance config is available")
		}
		outputValue = filepath.Join(config.WorkspaceRoot, hostAgentBinRelativePath)
	}
	outputPath, err := filepath.Abs(outputValue)
	if err != nil {
		return fmt.Errorf("resolve output path: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(outputPath), 0o755); err != nil {
		return fmt.Errorf("create output directory: %w", err)
	}
	switch resolution.mode {
	case "package-dir":
		if err := installAgentFromPackageDir(resolution.packageDir, resolvedTarget, outputPath, version); err != nil {
			if !resolution.allowFallback {
				return err
			}
		} else {
			fmt.Fprintf(stdout, "agent_installed target=%s output=%s source=package-dir package_dir=%s\n", resolvedTarget, outputPath, resolution.packageDir)
			return nil
		}
	}

	if instanceConfigErr != nil && strings.TrimSpace(*composeProject) == "" && strings.TrimSpace(*composeFile) == "" {
		return instanceConfigErr
	}

	composePrefix := composeArgs(config)
	if *build {
		if _, err := runExternal(runner, "docker", append(composePrefix, "build", config.RuntimeService)...); err != nil {
			return err
		}
	}
	var containerID string
	err = withComposeEnv(config, func() error {
		if err := cleanupLegacyRuntimeServiceOrphans(config, runner, stdout); err != nil {
			return err
		}
		if _, err := runExternal(runner, "docker", append(composePrefix, "up", "-d", "--no-deps", config.RuntimeService)...); err != nil {
			return err
		}
		containerBytes, err := runExternal(runner, "docker", append(composePrefix, "ps", "-q", config.RuntimeService)...)
		if err != nil {
			return err
		}
		containerID = strings.TrimSpace(string(containerBytes))
		if containerID == "" {
			return fmt.Errorf("A2O runtime container not found; run a2o runtime up")
		}
		return nil
	})
	if err != nil {
		return err
	}

	if _, err := runExternal(runner, "docker", "exec", containerID, "a3", "agent", "package", "verify", "--target", resolvedTarget); err != nil {
		return err
	}
	if _, err := runExternal(runner, "docker", "exec", containerID, "a3", "agent", "package", "export", "--target", resolvedTarget, "--output", *runtimeOutput); err != nil {
		return err
	}
	if _, err := runExternal(runner, "docker", "cp", containerID+":"+*runtimeOutput, outputPath); err != nil {
		return err
	}
	if err := os.Chmod(outputPath, 0o755); err != nil {
		return fmt.Errorf("chmod exported agent: %w", err)
	}

	fmt.Fprintf(stdout, "agent_installed target=%s output=%s source=runtime-image\n", resolvedTarget, outputPath)
	return nil
}

type agentInstallResolution struct {
	mode          string
	packageDir    string
	allowFallback bool
}

func resolveAgentPackageInstallSource(source, packageDir string) (agentInstallResolution, error) {
	resolvedSource := strings.TrimSpace(source)
	if resolvedSource == "" {
		resolvedSource = "auto"
	}
	resolvedDir := strings.TrimSpace(packageDir)
	explicitDir := resolvedDir != ""
	if !explicitDir {
		if strings.TrimSpace(os.Getenv("A3_AGENT_PACKAGE_DIR")) != "" {
			return agentInstallResolution{}, removedA3InputError("environment variable A3_AGENT_PACKAGE_DIR", "environment variable A2O_AGENT_PACKAGE_DIR")
		}
		resolvedDir = strings.TrimSpace(os.Getenv("A2O_AGENT_PACKAGE_DIR"))
	}

	switch resolvedSource {
	case "auto":
		if resolvedDir != "" {
			return agentInstallResolution{
				mode:          "package-dir",
				packageDir:    resolvedDir,
				allowFallback: !explicitDir,
			}, nil
		}
		return agentInstallResolution{mode: "runtime-image"}, nil
	case "package-dir":
		if resolvedDir == "" {
			return agentInstallResolution{}, errors.New("--package-dir or A2O_AGENT_PACKAGE_DIR is required when --package-source=package-dir")
		}
		return agentInstallResolution{mode: "package-dir", packageDir: resolvedDir}, nil
	case "runtime-image":
		return agentInstallResolution{mode: "runtime-image"}, nil
	default:
		return agentInstallResolution{}, fmt.Errorf("unsupported --package-source: %s", resolvedSource)
	}
}

type agentPackageContract struct {
	Schema          string `json:"schema"`
	PackageVersion  string `json:"package_version"`
	RuntimeVersion  string `json:"runtime_version"`
	ArchiveManifest string `json:"archive_manifest"`
	LauncherLayout  string `json:"launcher_layout"`
}

type agentPackageManifestEntry struct {
	Version string `json:"version"`
	Goos    string `json:"goos"`
	Goarch  string `json:"goarch"`
	Archive string `json:"archive"`
	SHA256  string `json:"sha256"`
}

func installAgentFromPackageDir(packageDir, target, outputPath, expectedRuntimeVersion string) error {
	dir := filepath.Clean(packageDir)
	entry, err := resolveAgentPackageEntry(dir, target, expectedRuntimeVersion)
	if err != nil {
		return err
	}
	archivePath := filepath.Join(dir, entry.Archive)
	archiveBody, err := os.ReadFile(archivePath)
	if err != nil {
		return fmt.Errorf("read agent package archive: %w", err)
	}
	actualSHA := sha256.Sum256(archiveBody)
	if fmt.Sprintf("%x", actualSHA[:]) != entry.SHA256 {
		return fmt.Errorf("agent package checksum mismatch for %s", target)
	}
	if err := extractAgentArchiveBinary(archivePath, outputPath); err != nil {
		return err
	}
	if err := os.Chmod(outputPath, 0o755); err != nil {
		return fmt.Errorf("chmod exported agent: %w", err)
	}
	return nil
}

func resolveAgentPackageEntry(packageDir, target, expectedRuntimeVersion string) (agentPackageManifestEntry, error) {
	contract, err := readAgentPackageContract(packageDir)
	if err != nil {
		return agentPackageManifestEntry{}, err
	}
	manifestPath := filepath.Join(packageDir, "release-manifest.jsonl")
	if contract != nil {
		if contract.Schema != "a2o-agent-package-compatibility/v1" {
			return agentPackageManifestEntry{}, fmt.Errorf("unsupported agent package compatibility schema: %s", contract.Schema)
		}
		if strings.TrimSpace(contract.RuntimeVersion) != strings.TrimSpace(expectedRuntimeVersion) {
			return agentPackageManifestEntry{}, fmt.Errorf("agent package runtime compatibility mismatch: package_runtime_version=%s expected_runtime_version=%s", contract.RuntimeVersion, expectedRuntimeVersion)
		}
		manifestName := strings.TrimSpace(contract.ArchiveManifest)
		if manifestName == "" {
			return agentPackageManifestEntry{}, errors.New("agent package compatibility contract is missing archive_manifest")
		}
		manifestPath = filepath.Join(packageDir, manifestName)
	}
	entries, err := readAgentPackageManifest(manifestPath)
	if err != nil {
		return agentPackageManifestEntry{}, err
	}
	manifestVersion := uniqueAgentPackageVersion(entries)
	if manifestVersion == "__mixed__" {
		return agentPackageManifestEntry{}, errors.New("agent package manifest mixes multiple package versions")
	}
	if contract != nil && strings.TrimSpace(contract.PackageVersion) != manifestVersion {
		return agentPackageManifestEntry{}, fmt.Errorf("agent package contract mismatch: contract_package_version=%s manifest_package_version=%s", contract.PackageVersion, manifestVersion)
	}
	if contract == nil && manifestVersion != "" && strings.TrimSpace(expectedRuntimeVersion) != manifestVersion {
		return agentPackageManifestEntry{}, fmt.Errorf("agent package runtime compatibility mismatch: package_runtime_version=%s expected_runtime_version=%s", manifestVersion, expectedRuntimeVersion)
	}
	normalizedTarget := strings.ReplaceAll(strings.TrimSpace(target), "/", "-")
	for _, entry := range entries {
		if entry.Goos+"-"+entry.Goarch == normalizedTarget {
			return entry, nil
		}
	}
	return agentPackageManifestEntry{}, fmt.Errorf("agent package target not found: %s", target)
}

func readAgentPackageContract(packageDir string) (*agentPackageContract, error) {
	path := filepath.Join(packageDir, "package-compatibility.json")
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		return nil, nil
	} else if err != nil {
		return nil, fmt.Errorf("read agent package compatibility contract: %w", err)
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read agent package compatibility contract: %w", err)
	}
	var contract agentPackageContract
	if err := json.Unmarshal(body, &contract); err != nil {
		return nil, fmt.Errorf("invalid agent package compatibility contract: %w", err)
	}
	return &contract, nil
}

func readAgentPackageManifest(path string) ([]agentPackageManifestEntry, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("agent package manifest not found: %s", path)
		}
		return nil, fmt.Errorf("read agent package manifest: %w", err)
	}
	lines := strings.Split(strings.TrimSpace(string(body)), "\n")
	entries := make([]agentPackageManifestEntry, 0, len(lines))
	for _, line := range lines {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var entry agentPackageManifestEntry
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			return nil, fmt.Errorf("invalid agent package manifest: %s (%w)", path, err)
		}
		entries = append(entries, entry)
	}
	return entries, nil
}

func uniqueAgentPackageVersion(entries []agentPackageManifestEntry) string {
	seen := map[string]struct{}{}
	versions := make([]string, 0, len(entries))
	for _, entry := range entries {
		version := strings.TrimSpace(entry.Version)
		if version == "" {
			continue
		}
		if _, ok := seen[version]; ok {
			continue
		}
		seen[version] = struct{}{}
		versions = append(versions, version)
	}
	switch len(versions) {
	case 0:
		return ""
	case 1:
		return versions[0]
	default:
		return "__mixed__"
	}
}

func extractAgentArchiveBinary(archivePath, outputPath string) error {
	file, err := os.Open(archivePath)
	if err != nil {
		return fmt.Errorf("open agent package archive: %w", err)
	}
	defer file.Close()
	gzipReader, err := gzip.NewReader(file)
	if err != nil {
		return fmt.Errorf("open agent package gzip stream: %w", err)
	}
	defer gzipReader.Close()
	tarReader := tar.NewReader(gzipReader)
	for {
		header, err := tarReader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return fmt.Errorf("read agent package archive: %w", err)
		}
		if header.Typeflag != tar.TypeReg || filepath.Base(header.Name) != "a2o-agent" {
			continue
		}
		if err := os.MkdirAll(filepath.Dir(outputPath), 0o755); err != nil {
			return fmt.Errorf("create output directory: %w", err)
		}
		out, err := os.Create(outputPath)
		if err != nil {
			return fmt.Errorf("create exported agent: %w", err)
		}
		if _, err := io.Copy(out, tarReader); err != nil {
			out.Close()
			return fmt.Errorf("write exported agent: %w", err)
		}
		if err := out.Close(); err != nil {
			return fmt.Errorf("close exported agent: %w", err)
		}
		return nil
	}
	return fmt.Errorf("agent package archive does not contain a2o-agent: %s; migration_required=true replacement_archive=a2o-agent-<version>-<os>-<arch>.tar.gz", archivePath)
}

func firstNonEmptyString(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func detectHostTarget() (string, error) {
	var osPart string
	switch runtime.GOOS {
	case "darwin", "linux":
		osPart = runtime.GOOS
	default:
		return "", fmt.Errorf("unsupported host OS: %s", runtime.GOOS)
	}

	var archPart string
	switch runtime.GOARCH {
	case "amd64", "arm64":
		archPart = runtime.GOARCH
	default:
		return "", fmt.Errorf("unsupported host architecture: %s", runtime.GOARCH)
	}

	return osPart + "-" + archPart, nil
}
