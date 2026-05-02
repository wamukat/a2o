package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestProjectTemplatePrintsValidMinimalProjectYaml(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"project",
		"template",
		"--package-name",
		"sample-product",
		"--kanban-project",
		"SampleProduct",
		"--language",
		"node",
		"--executor-bin",
		"a2o-worker",
		"--repo-label",
		"repo:app",
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}

	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "project-package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), stdout.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(stdout.String(), "prompt_transport") || strings.Contains(stdout.String(), "default_profile") || strings.Contains(stdout.String(), "phase_profiles") {
		t.Fatalf("template should use compact executor syntax, got:\n%s", stdout.String())
	}
	if strings.Contains(stdout.String(), "provider: kanbalone") {
		t.Fatalf("template should not expose fixed kanban provider, got:\n%s", stdout.String())
	}
	config, err := loadProjectPackageConfig(packageDir)
	if err != nil {
		t.Fatalf("generated project.yaml should load: %v\n%s", err, stdout.String())
	}
	if config.PackageName != "sample-product" {
		t.Fatalf("PackageName=%q", config.PackageName)
	}
	if config.KanbanProject != "SampleProduct" {
		t.Fatalf("KanbanProject=%q", config.KanbanProject)
	}
	if !strings.Contains(stdout.String(), "a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent") {
		t.Fatalf("template should document canonical agent install path, got:\n%s", stdout.String())
	}
	if config.Repos["app"].Label != "repo:app" {
		t.Fatalf("repo label=%q", config.Repos["app"].Label)
	}
	for _, want := range []string{"git", "node", "npm", "a2o-worker"} {
		if !containsString(config.AgentRequiredBins, want) {
			t.Fatalf("required_bins missing %q in %#v", want, config.AgentRequiredBins)
		}
	}
	command := config.Executor["default_profile"].(map[string]any)["command"].([]any)
	if strings.Join([]string{
		command[0].(string),
		command[1].(string),
		command[2].(string),
		command[3].(string),
		command[4].(string),
	}, " ") != "a2o-worker --schema {{schema_path}} --result {{result_path}}" {
		t.Fatalf("unexpected executor command: %#v", command)
	}
}

func TestProjectTemplateWritesOutputFileWithCustomExecutorArgs(t *testing.T) {
	tempDir := t.TempDir()
	outputPath := filepath.Join(tempDir, "project-package", "project.yaml")
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"project",
		"template",
		"--package-name",
		"python-product",
		"--kanban-project",
		"PythonProduct",
		"--language",
		"python",
		"--executor-bin",
		"custom-worker",
		"--executor-arg",
		"run",
		"--executor-arg",
		"--out={{result_path}}",
		"--output",
		outputPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "project_template_written path="+outputPath) {
		t.Fatalf("stdout should describe output path, got %q", stdout.String())
	}
	if strings.Contains(stdout.String(), "kanban_bootstrap_template_written") {
		t.Fatalf("template should not write a separate kanban bootstrap file, got %q", stdout.String())
	}
	body, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatalf("project template missing: %v", err)
	}
	if strings.Contains(string(body), "provider: kanbalone") {
		t.Fatalf("template should not expose fixed kanban provider:\n%s", string(body))
	}
	if strings.Contains(string(body), "bootstrap:") || strings.Contains(string(body), "bootstrap.json") {
		t.Fatalf("template should inline kanban bootstrap into project.yaml:\n%s", string(body))
	}
	config, err := loadProjectPackageConfig(filepath.Dir(outputPath))
	if err != nil {
		t.Fatalf("generated project.yaml should load: %v", err)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(outputPath), "kanban", "bootstrap.json")); !os.IsNotExist(err) {
		t.Fatalf("template should not create kanban/bootstrap.json, err=%v", err)
	}
	command := config.Executor["default_profile"].(map[string]any)["command"].([]any)
	if got := command[0].(string) + " " + command[1].(string) + " " + command[2].(string); got != "custom-worker run --out={{result_path}}" {
		t.Fatalf("unexpected executor command: %s", got)
	}
	if !containsString(config.AgentRequiredBins, "python3") {
		t.Fatalf("python template should include python3 in %#v", config.AgentRequiredBins)
	}
}

func TestProjectTemplateWithSkillsWritesPhaseSkillFiles(t *testing.T) {
	tempDir := t.TempDir()
	outputPath := filepath.Join(tempDir, "project-package", "project.yaml")
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"project",
		"template",
		"--package-name",
		"skill-product",
		"--kanban-project",
		"SkillProduct",
		"--executor-bin",
		"skill-worker",
		"--with-skills",
		"--skill-language",
		"en",
		"--output",
		outputPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}
	for _, rel := range []string{
		"skills/implementation/base.md",
		"skills/review/default.md",
		"skills/review/parent.md",
	} {
		path := filepath.Join(filepath.Dir(outputPath), filepath.FromSlash(rel))
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("skill template %s missing: %v", rel, err)
		}
		required := map[string][]string{
			"skills/implementation/base.md": {"Repository Boundary", "Verification Evidence"},
			"skills/review/default.md":      {"Findings", "Evidence"},
			"skills/review/parent.md":       {"Integration Boundary", "Evidence"},
		}[rel]
		for _, want := range required {
			if !strings.Contains(string(body), want) {
				t.Fatalf("skill template %s missing %q:\n%s", rel, want, string(body))
			}
		}
		if !strings.Contains(stdout.String(), "project_skill_template_written path="+path) {
			t.Fatalf("stdout should mention skill template %s, got %q", path, stdout.String())
		}
	}
	projectYaml, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"skill: \"skills/implementation/base.md\"",
		"skill: \"skills/review/default.md\"",
		"skill: \"skills/review/parent.md\"",
		"parent_review:",
	} {
		if !strings.Contains(string(projectYaml), want) {
			t.Fatalf("project.yaml missing %q:\n%s", want, string(projectYaml))
		}
	}
	if _, err := loadProjectPackageConfig(filepath.Dir(outputPath)); err != nil {
		t.Fatalf("generated project.yaml should load: %v", err)
	}
}

func TestProjectTemplateWithSkillsRequiresOutputPath(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{"project", "template", "--with-skills"}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("run should fail")
	}
	if !strings.Contains(stderr.String(), "--with-skills requires --output") {
		t.Fatalf("stderr should explain output requirement, got %q", stderr.String())
	}
}

func TestProjectTemplateWithSkillsPreflightsBeforeWritingProjectYaml(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "project-package")
	outputPath := filepath.Join(packageDir, "project.yaml")
	existingSkill := filepath.Join(packageDir, "skills", "review", "default.md")
	if err := os.MkdirAll(filepath.Dir(existingSkill), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(existingSkill, []byte("existing\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"project",
		"template",
		"--with-skills",
		"--output",
		outputPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("run should fail when a skill template exists")
	}
	if !strings.Contains(stderr.String(), "skill template already exists") {
		t.Fatalf("stderr should explain existing skill, got %q", stderr.String())
	}
	if _, err := os.Stat(outputPath); !os.IsNotExist(err) {
		t.Fatalf("project.yaml should not be written after skill preflight failure, err=%v", err)
	}
	if _, err := os.Stat(filepath.Join(packageDir, "skills", "implementation", "base.md")); !os.IsNotExist(err) {
		t.Fatalf("implementation skill should not be partially written, err=%v", err)
	}
	body, err := os.ReadFile(existingSkill)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "existing\n" {
		t.Fatalf("existing skill should be untouched, got %q", string(body))
	}
}

func TestProjectTemplateWithSkillsDoesNotLeaveProjectYamlOnSkillWriteFailure(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "project-package")
	outputPath := filepath.Join(packageDir, "project.yaml")
	if err := os.MkdirAll(filepath.Join(packageDir, "skills"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageDir, "skills", "review"), []byte("not a directory\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"project",
		"template",
		"--with-skills",
		"--force",
		"--output",
		outputPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("run should fail when a skill template parent cannot be created")
	}
	if !strings.Contains(stderr.String(), "create template directory") {
		t.Fatalf("stderr should explain template directory failure, got %q", stderr.String())
	}
	if _, err := os.Stat(outputPath); !os.IsNotExist(err) {
		t.Fatalf("project.yaml should not be written after skill write failure, err=%v", err)
	}
	if _, err := os.Stat(filepath.Join(packageDir, "skills", "implementation", "base.md")); !os.IsNotExist(err) {
		t.Fatalf("implementation skill should not be partially written, err=%v", err)
	}
}

func TestProjectTemplateRefusesToOverwriteWithoutForce(t *testing.T) {
	tempDir := t.TempDir()
	outputPath := filepath.Join(tempDir, "project-package", "project.yaml")
	if err := os.MkdirAll(filepath.Dir(outputPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(outputPath, []byte("existing\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"project",
		"template",
		"--output",
		outputPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("run should fail when output exists")
	}
	if !strings.Contains(stderr.String(), "pass --force to overwrite") {
		t.Fatalf("stderr should explain force, got %q", stderr.String())
	}
	body, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "existing\n" {
		t.Fatalf("existing file should not be overwritten, got %q", string(body))
	}
}
