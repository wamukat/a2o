package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
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
	case "lint":
		return runProjectLint(args[1:], stdout, stderr)
	case "validate":
		return runProjectValidate(args[1:], stdout, stderr)
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
	withSkills := flags.Bool("with-skills", false, "also write phase skill templates next to project.yaml")
	skillLanguage := flags.String("skill-language", "en", "skill template language: en or ja")
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
		WithSkills:    *withSkills,
	})
	if err != nil {
		return err
	}
	if strings.TrimSpace(*outputPath) == "" || *outputPath == "-" {
		if *withSkills {
			return fmt.Errorf("--with-skills requires --output to point to project.yaml")
		}
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
	var skillTemplates []plannedTemplateFile
	if *withSkills {
		var err error
		skillTemplates, err = planProjectSkillTemplates(filepath.Dir(*outputPath), strings.TrimSpace(*skillLanguage), *force)
		if err != nil {
			return err
		}
	}
	if err := os.MkdirAll(filepath.Dir(*outputPath), 0o755); err != nil {
		return fmt.Errorf("create output directory: %w", err)
	}
	files := []plannedTemplateFile{{Path: *outputPath, Body: template}}
	files = append(files, skillTemplates...)
	if err := writePlannedTemplateFiles(files); err != nil {
		return err
	}
	if *withSkills {
		for _, template := range skillTemplates {
			fmt.Fprintf(stdout, "project_skill_template_written path=%s\n", template.Path)
		}
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
	WithSkills    bool
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
	if options.WithSkills {
		builder.WriteString("    parent_review:\n")
		writeYAMLScalar(&builder, 3, "skill", "skills/review/parent.md")
		builder.WriteString("      executor:\n")
		builder.WriteString("        command:\n")
		writeYAMLList(&builder, 5, executorCommand)
	}
	builder.WriteString("    verification:\n")
	builder.WriteString("      commands: []\n")
	builder.WriteString("    remediation:\n")
	builder.WriteString("      commands: []\n")
	builder.WriteString("    merge:\n")
	writeYAMLScalar(&builder, 3, "policy", "ff_only")
	writeYAMLScalar(&builder, 3, "target_ref", "refs/heads/main")
	return builder.String(), nil
}

type plannedTemplateFile struct {
	Path string
	Body string
}

func planProjectSkillTemplates(packageDir string, language string, force bool) ([]plannedTemplateFile, error) {
	templates, err := projectSkillTemplates(language)
	if err != nil {
		return nil, err
	}
	planned := []plannedTemplateFile{}
	for relativePath, body := range templates {
		path := filepath.Join(packageDir, filepath.FromSlash(relativePath))
		if !force {
			if _, err := os.Stat(path); err == nil {
				return nil, fmt.Errorf("skill template already exists: %s; pass --force to overwrite", path)
			} else if err != nil && !os.IsNotExist(err) {
				return nil, fmt.Errorf("inspect skill template: %w", err)
			}
		}
		planned = append(planned, plannedTemplateFile{Path: path, Body: body})
	}
	sort.Slice(planned, func(left int, right int) bool {
		return planned[left].Path < planned[right].Path
	})
	return planned, nil
}

func writePlannedTemplateFiles(files []plannedTemplateFile) error {
	tempPaths := []string{}
	committedPaths := []string{}
	cleanupTemps := func() {
		for _, path := range tempPaths {
			_ = os.Remove(path)
		}
	}
	cleanupCommitted := func() {
		for _, path := range committedPaths {
			_ = os.Remove(path)
		}
	}
	for _, file := range files {
		if err := os.MkdirAll(filepath.Dir(file.Path), 0o755); err != nil {
			cleanupTemps()
			return fmt.Errorf("create template directory: %w", err)
		}
		tempFile, err := os.CreateTemp(filepath.Dir(file.Path), "."+filepath.Base(file.Path)+".tmp-*")
		if err != nil {
			cleanupTemps()
			return fmt.Errorf("create temporary template file: %w", err)
		}
		tempPath := tempFile.Name()
		tempPaths = append(tempPaths, tempPath)
		if _, err := tempFile.WriteString(file.Body); err != nil {
			_ = tempFile.Close()
			cleanupTemps()
			return fmt.Errorf("write temporary template file: %w", err)
		}
		if err := tempFile.Chmod(0o644); err != nil {
			_ = tempFile.Close()
			cleanupTemps()
			return fmt.Errorf("chmod temporary template file: %w", err)
		}
		if err := tempFile.Close(); err != nil {
			cleanupTemps()
			return fmt.Errorf("close temporary template file: %w", err)
		}
	}
	for index, file := range files {
		tempPath := tempPaths[index]
		if err := os.Rename(tempPath, file.Path); err != nil {
			cleanupTemps()
			cleanupCommitted()
			return fmt.Errorf("write template file: %w", err)
		}
		committedPaths = append(committedPaths, file.Path)
	}
	return nil
}

func projectSkillTemplates(language string) (map[string]string, error) {
	switch strings.ToLower(strings.TrimSpace(language)) {
	case "", "en":
		return map[string]string{
			"skills/implementation/base.md": projectImplementationSkillTemplateEN,
			"skills/review/default.md":      projectReviewSkillTemplateEN,
			"skills/review/parent.md":       projectParentReviewSkillTemplateEN,
		}, nil
	case "ja":
		return map[string]string{
			"skills/implementation/base.md": projectImplementationSkillTemplateJA,
			"skills/review/default.md":      projectReviewSkillTemplateJA,
			"skills/review/parent.md":       projectParentReviewSkillTemplateJA,
		}, nil
	default:
		return nil, fmt.Errorf("--skill-language must be one of en, ja")
	}
}

const projectImplementationSkillTemplateEN = `# Implementation Skill

Use this skill for A2O implementation phases.

## Repository Boundary

- Edit only the repository slots and paths named by the task.
- Keep generated runtime files under .work/a2o/ out of commits.
- Do not change kanban state directly from the worker.

## Work Rules

- Read the task, affected files, and relevant project docs before editing.
- Keep changes scoped to the requested behavior.
- Update docs or task templates when the behavior surface changes.

## Verification Evidence

- Run the narrowest command that proves the change.
- Record command names, exit status, and important output in the worker result.
- If verification cannot run, explain the blocker and the exact follow-up command.

## Knowledge

- Use only task-specific project knowledge commands described by the package.
- Treat source, docs, tests, and verification as authoritative.
`

const projectReviewSkillTemplateEN = `# Review Skill

Use this skill for A2O review phases.

## Findings

Report findings for correctness bugs, missing verification, unsafe repo boundary changes, public API/SPI drift, migration gaps, and documentation gaps.

## Evidence

- Check the implementation diff and the recorded verification evidence.
- Confirm changed behavior has an appropriate test or an explicit reason.
- Mention residual risk when verification is incomplete.

## Output

- Lead with findings, ordered by severity.
- Say "No findings" when no actionable issue remains.
`

const projectParentReviewSkillTemplateEN = `# Parent Review Skill

Use this skill for parent review or multi-repo integration phases.

## Integration Boundary

- Check child task outputs before reviewing the combined result.
- Confirm repository slots, branch targets, and merge readiness.
- Verify cross-repo API/SPI assumptions that changed during child work.

## Evidence

- Prefer an all-repo verification command when available.
- Record which child outputs were reviewed and which command proves integration.
- Report merge blockers before approving parent completion.
`

const projectImplementationSkillTemplateJA = `# Implementation Skill

A2O の implementation phase で使う skill である。

## Repository Boundary

- Task が指定した repo slot と path だけを編集する。
- .work/a2o/ 配下の generated runtime files は commit に含めない。
- Worker から kanban state を直接変更しない。

## Work Rules

- 編集前に task、影響 file、関連 project docs を読む。
- 変更は要求された behavior に絞る。
- Behavior surface が変わる場合は docs や task template も更新する。

## Verification Evidence

- 変更を証明する最小 command を実行する。
- Command 名、exit status、重要 output を worker result に記録する。
- Verification を実行できない場合は blocker と follow-up command を明記する。

## Knowledge

- Package が説明している task-specific な project knowledge command だけを使う。
- Source、docs、tests、verification を authoritative として扱う。
`

const projectReviewSkillTemplateJA = `# Review Skill

A2O の review phase で使う skill である。

## Findings

Correctness bug、verification 不足、危険な repo boundary 変更、public API/SPI drift、migration gap、documentation gap を finding として報告する。

## Evidence

- Implementation diff と記録された verification evidence を確認する。
- 変更 behavior に適切な test、または明示された理由があることを確認する。
- Verification が不完全な場合は residual risk を書く。

## Output

- Finding を severity 順に先に書く。
- Actionable issue が残っていない場合は "No findings" と書く。
`

const projectParentReviewSkillTemplateJA = `# Parent Review Skill

Parent review または multi-repo integration phase で使う skill である。

## Integration Boundary

- Combined result を review する前に child task output を確認する。
- Repository slot、branch target、merge readiness を確認する。
- Child work で変わった cross-repo API/SPI assumption を確認する。

## Evidence

- 利用可能であれば all-repo verification command を優先する。
- どの child output を確認したか、どの command が integration を証明したかを記録する。
- Parent completion を承認する前に merge blocker を報告する。
`

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
		RuntimeImage:   defaultRuntimeImage(),
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
