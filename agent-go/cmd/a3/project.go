package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func runProject(args []string, stdout io.Writer, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "missing project subcommand")
		printUsage(stderr)
		return 2
	}
	if isHelpArg(args[0]) {
		printUsage(stdout)
		return 0
	}
	switch args[0] {
	case "bootstrap":
		if err := runProjectBootstrap(args[1:], stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "template":
		if err := runProjectTemplate(args[1:], stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	default:
		fmt.Fprintf(stderr, "unknown project subcommand: %s\n", args[0])
		printUsage(stderr)
		return 2
	}
}

type stringListFlag []string

func (values *stringListFlag) String() string {
	return strings.Join(*values, " ")
}

func (values *stringListFlag) Set(value string) error {
	*values = append(*values, value)
	return nil
}

func runProjectTemplate(args []string, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o project template", flag.ContinueOnError)
	flags.SetOutput(stderr)

	packageName := flags.String("package-name", "my-a2o-project", "package.name value")
	kanbanProject := flags.String("kanban-project", "MyA2OProject", "kanban.project value")
	repoPath := flags.String("repo-path", "..", "product repo path relative to the package directory")
	repoLabel := flags.String("repo-label", "", "optional kanban label for the app repo slot")
	language := flags.String("language", "generic", "toolchain preset: generic, node, go, python, ruby")
	executorBin := flags.String("executor-bin", "your-ai-worker", "agent-side executor binary")
	outputPath := flags.String("output", "-", "output project.yaml path, or - for stdout")
	force := flags.Bool("force", false, "overwrite existing generated files")
	var executorArgs stringListFlag
	flags.Var(&executorArgs, "executor-arg", "executor argument; repeat to override the default --schema/--result arguments")

	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	template, err := buildProjectTemplate(projectTemplateOptions{
		PackageName:   strings.TrimSpace(*packageName),
		KanbanProject: strings.TrimSpace(*kanbanProject),
		RepoPath:      strings.TrimSpace(*repoPath),
		RepoLabel:     strings.TrimSpace(*repoLabel),
		Language:      strings.TrimSpace(*language),
		ExecutorBin:   strings.TrimSpace(*executorBin),
		ExecutorArgs:  executorArgs,
	})
	if err != nil {
		return err
	}
	if strings.TrimSpace(*outputPath) == "" || *outputPath == "-" {
		_, err := io.WriteString(stdout, template)
		return err
	}
	if !*force {
		if _, err := os.Stat(*outputPath); err == nil {
			return fmt.Errorf("output file already exists: %s; pass --force to overwrite", *outputPath)
		} else if err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("inspect output file: %w", err)
		}
	}
	if err := os.MkdirAll(filepath.Dir(*outputPath), 0o755); err != nil {
		return fmt.Errorf("create output directory: %w", err)
	}
	if err := os.WriteFile(*outputPath, []byte(template), 0o644); err != nil {
		return fmt.Errorf("write project template: %w", err)
	}
	fmt.Fprintf(stdout, "project_template_written path=%s\n", *outputPath)
	return nil
}

type projectTemplateOptions struct {
	PackageName   string
	KanbanProject string
	RepoPath      string
	RepoLabel     string
	Language      string
	ExecutorBin   string
	ExecutorArgs  []string
}

func buildProjectTemplate(options projectTemplateOptions) (string, error) {
	if options.PackageName == "" {
		return "", errors.New("--package-name must not be blank")
	}
	if options.KanbanProject == "" {
		return "", errors.New("--kanban-project must not be blank")
	}
	if options.RepoPath == "" {
		return "", errors.New("--repo-path must not be blank")
	}
	if options.ExecutorBin == "" {
		return "", errors.New("--executor-bin must not be blank")
	}
	repoLabel := options.RepoLabel
	if repoLabel == "" {
		repoLabel = "repo:app"
	}
	requiredBins, err := templateRequiredBins(options.Language, options.ExecutorBin)
	if err != nil {
		return "", err
	}
	executorCommand := append([]string{options.ExecutorBin}, options.ExecutorArgs...)
	if len(options.ExecutorArgs) == 0 {
		executorCommand = []string{options.ExecutorBin, "--schema", "{{schema_path}}", "--result", "{{result_path}}"}
	}

	var builder strings.Builder
	builder.WriteString("# Install the host agent at the canonical path before runtime execution:\n")
	builder.WriteString("# a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent\n")
	builder.WriteString("schema_version: 1\n")
	builder.WriteString("package:\n")
	writeYAMLScalar(&builder, 1, "name", options.PackageName)
	builder.WriteString("kanban:\n")
	writeYAMLScalar(&builder, 1, "project", options.KanbanProject)
	builder.WriteString("  selection:\n")
	writeYAMLScalar(&builder, 2, "status", "To do")
	builder.WriteString("repos:\n")
	builder.WriteString("  app:\n")
	writeYAMLScalar(&builder, 2, "path", options.RepoPath)
	writeYAMLScalar(&builder, 2, "role", "product")
	writeYAMLScalar(&builder, 2, "label", repoLabel)
	builder.WriteString("agent:\n")
	writeYAMLScalar(&builder, 1, "workspace_root", ".work/a2o/agent/workspaces")
	builder.WriteString("  required_bins:\n")
	writeYAMLList(&builder, 2, requiredBins)
	builder.WriteString("runtime:\n")
	builder.WriteString("  max_steps: 20\n")
	builder.WriteString("  agent_attempts: 200\n")
	builder.WriteString("  phases:\n")
	builder.WriteString("    implementation:\n")
	writeYAMLScalar(&builder, 3, "skill", "skills/implementation/base.md")
	builder.WriteString("      executor:\n")
	builder.WriteString("        command:\n")
	writeYAMLList(&builder, 5, executorCommand)
	builder.WriteString("    review:\n")
	writeYAMLScalar(&builder, 3, "skill", "skills/review/default.md")
	builder.WriteString("      executor:\n")
	builder.WriteString("        command:\n")
	writeYAMLList(&builder, 5, executorCommand)
	builder.WriteString("    verification:\n")
	builder.WriteString("      commands: []\n")
	builder.WriteString("    remediation:\n")
	builder.WriteString("      commands: []\n")
	builder.WriteString("    merge:\n")
	writeYAMLScalar(&builder, 3, "target", "merge_to_live")
	writeYAMLScalar(&builder, 3, "policy", "ff_only")
	writeYAMLScalar(&builder, 3, "target_ref", "refs/heads/main")
	return builder.String(), nil
}

func templateRequiredBins(language string, executorBin string) ([]string, error) {
	bins := []string{"git"}
	switch strings.ToLower(language) {
	case "", "generic":
	case "node", "typescript", "javascript":
		bins = append(bins, "node", "npm")
	case "go", "golang":
		bins = append(bins, "go")
	case "python", "python3":
		bins = append(bins, "python3")
	case "ruby":
		bins = append(bins, "ruby")
	default:
		return nil, fmt.Errorf("--language must be one of generic, node, go, python, ruby")
	}
	if !containsString(bins, executorBin) {
		bins = append(bins, executorBin)
	}
	return bins, nil
}

func writeYAMLScalar(builder *strings.Builder, indent int, key string, value string) {
	builder.WriteString(strings.Repeat("  ", indent))
	builder.WriteString(key)
	builder.WriteString(": ")
	builder.WriteString(strconv.Quote(value))
	builder.WriteString("\n")
}

func writeYAMLList(builder *strings.Builder, indent int, values []string) {
	for _, value := range values {
		builder.WriteString(strings.Repeat("  ", indent))
		builder.WriteString("- ")
		builder.WriteString(strconv.Quote(value))
		builder.WriteString("\n")
	}
}

func runProjectBootstrap(args []string, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o project bootstrap", flag.ContinueOnError)
	flags.SetOutput(stderr)

	packagePath := flags.String("package", "", "project package directory")
	workspaceRoot := flags.String("workspace", ".", "workspace root where .work/a2o/runtime-instance.json is written")
	composeProject := flags.String("compose-project", "", "docker compose project name for this runtime instance")
	composeFile := flags.String("compose-file", "", "A2O distribution compose file")
	runtimeService := flags.String("runtime-service", "a2o-runtime", "docker compose runtime service name")
	soloBoardPort := flags.String("soloboard-port", "3470", "host kanban service port")
	agentPort := flags.String("agent-port", "7393", "host A2O agent control-plane port")
	storageDir := flags.String("storage-dir", "/var/lib/a2o/a2o-runtime", "runtime storage dir inside the A2O runtime container")

	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	absWorkspaceRoot, err := filepath.Abs(*workspaceRoot)
	if err != nil {
		return fmt.Errorf("resolve workspace root: %w", err)
	}
	resolvedPackagePath, err := resolveBootstrapPackagePath(*packagePath, absWorkspaceRoot)
	if err != nil {
		return err
	}
	absPackagePath, err := filepath.Abs(resolvedPackagePath)
	if err != nil {
		return fmt.Errorf("resolve package path: %w", err)
	}
	info, err := os.Stat(absPackagePath)
	if err != nil {
		return fmt.Errorf("project package not found: %w", err)
	}
	if !info.IsDir() {
		return fmt.Errorf("project package must be a directory: %s", absPackagePath)
	}

	projectName := strings.TrimSpace(*composeProject)
	if projectName == "" {
		projectName = defaultComposeProjectName(absPackagePath)
	}
	resolvedComposeFile := strings.TrimSpace(*composeFile)
	if resolvedComposeFile == "" {
		resolvedComposeFile = defaultComposeFile()
	}
	if absComposeFile, err := filepath.Abs(resolvedComposeFile); err == nil {
		resolvedComposeFile = absComposeFile
	}

	config := runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    absPackagePath,
		WorkspaceRoot:  absWorkspaceRoot,
		ComposeFile:    resolvedComposeFile,
		ComposeProject: projectName,
		RuntimeService: strings.TrimSpace(*runtimeService),
		SoloBoardPort:  strings.TrimSpace(*soloBoardPort),
		AgentPort:      strings.TrimSpace(*agentPort),
		StorageDir:     strings.TrimSpace(*storageDir),
	}
	if err := writeInstanceConfig(absWorkspaceRoot, config); err != nil {
		return err
	}

	fmt.Fprintf(stdout, "project_bootstrapped package=%s instance_config=%s\n", config.PackagePath, filepath.Join(absWorkspaceRoot, instanceConfigRelativePath))
	return nil
}

func resolveBootstrapPackagePath(packagePath string, workspaceRoot string) (string, error) {
	if strings.TrimSpace(packagePath) != "" {
		return strings.TrimSpace(packagePath), nil
	}
	candidates := []string{
		filepath.Join(workspaceRoot, "a2o-project"),
		filepath.Join(workspaceRoot, "project-package"),
	}
	matches := []string{}
	for _, candidate := range candidates {
		if info, err := os.Stat(candidate); err == nil && info.IsDir() {
			matches = append(matches, candidate)
		}
	}
	switch len(matches) {
	case 1:
		return matches[0], nil
	case 0:
		return "", errors.New("--package is required unless ./a2o-project or ./project-package exists")
	default:
		return "", errors.New("--package is required when both ./a2o-project and ./project-package exist")
	}
}
