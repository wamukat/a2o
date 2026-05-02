package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestProjectValidateRejectsMissingMergePolicy(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    review:
      skill: skills/review/default.md
      executor:
        command:
          - worker
    merge:
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project validate should fail for missing merge policy, stdout=%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "lint_check name=project_package status=blocked") ||
		!strings.Contains(stdout.String(), "invalid runtime.phases.merge") ||
		!strings.Contains(stdout.String(), "policy must be provided") {
		t.Fatalf("project validate should reject missing merge policy, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
}

func TestProjectValidateAcceptsMetricsPhaseCommands(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    review:
      skill: skills/review/default.md
      executor:
        command:
          - worker
    verification:
      commands:
        - task test
    metrics:
      commands:
        - task metrics
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	config, err := loadProjectPackageConfig(packageDir)
	if err != nil {
		t.Fatalf("loadProjectPackageConfig should accept metrics phase, got %v", err)
	}
	phaseProfiles, _ := config.Executor["phase_profiles"].(map[string]any)
	if _, ok := phaseProfiles["metrics"]; ok {
		t.Fatalf("metrics phase should not create an executor phase profile: %#v", phaseProfiles["metrics"])
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("project validate should accept metrics phase, code=%d stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
	if !strings.Contains(stdout.String(), "lint_check name=project_package status=ok") ||
		!strings.Contains(stdout.String(), "lint_status=ok") {
		t.Fatalf("project validate should report ok, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
}

func TestProjectValidateAcceptsSingleTaskSchedulerConfig(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	writeSchedulerValidationProjectPackage(t, packageDir, "  scheduler:\n    max_parallel_tasks: 1\n")

	config, err := loadProjectPackageConfig(packageDir)
	if err != nil {
		t.Fatalf("loadProjectPackageConfig should accept max_parallel_tasks=1, got %v", err)
	}
	if config.SchedulerMaxParallelTasks != "1" {
		t.Fatalf("SchedulerMaxParallelTasks=%q", config.SchedulerMaxParallelTasks)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("project validate should accept max_parallel_tasks=1, code=%d stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
	if !strings.Contains(stdout.String(), "lint_check name=project_package status=ok") {
		t.Fatalf("project validate should report ok, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
}

func TestProjectValidateRejectsMalformedSchedulerConfig(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	writeSchedulerValidationProjectPackage(t, packageDir, "  scheduler:\n    - invalid\n")

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project validate should reject malformed runtime.scheduler, stdout=%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "invalid runtime.scheduler") ||
		!strings.Contains(stdout.String(), "must be a mapping") {
		t.Fatalf("project validate should reject malformed runtime.scheduler, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
}

func TestProjectValidateRejectsInvalidSchedulerMaxParallelTasks(t *testing.T) {
	cases := []struct {
		name       string
		scheduler  string
		wantDetail string
	}{
		{
			name:       "non-integer",
			scheduler:  "  scheduler:\n    max_parallel_tasks: \"2\"\n",
			wantDetail: "max_parallel_tasks must be an integer",
		},
		{
			name:       "float",
			scheduler:  "  scheduler:\n    max_parallel_tasks: 1.0\n",
			wantDetail: "max_parallel_tasks must be an integer",
		},
		{
			name:       "lower than one",
			scheduler:  "  scheduler:\n    max_parallel_tasks: 0\n",
			wantDetail: "max_parallel_tasks must be greater than or equal to 1",
		},
		{
			name:       "unsupported parallelism",
			scheduler:  "  scheduler:\n    max_parallel_tasks: 2\n",
			wantDetail: "max_parallel_tasks > 1 is not supported yet",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tempDir := t.TempDir()
			packageDir := filepath.Join(tempDir, "package")
			writeSchedulerValidationProjectPackage(t, packageDir, tc.scheduler)

			var stdout bytes.Buffer
			var stderr bytes.Buffer
			code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
			if code == 0 {
				t.Fatalf("project validate should reject %s, stdout=%s", tc.name, stdout.String())
			}
			if !strings.Contains(stdout.String(), "invalid runtime.scheduler") ||
				!strings.Contains(stdout.String(), tc.wantDetail) {
				t.Fatalf("project validate should reject %s, stdout=%s stderr=%s", tc.name, stdout.String(), stderr.String())
			}
		})
	}
}

func TestProjectValidateAcceptsRemoteBranchDeliveryConfig(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	writeSchedulerValidationProjectPackage(t, packageDir, `  delivery:
    mode: remote_branch
    remote: origin
    base_branch: main
    branch_prefix: a2o/
    push: true
    sync:
      before_start: fetch
      before_resume: fetch
      before_push: fetch
      integrate_base: none
      conflict_policy: stop
    after_push:
      command:
        - commands/after-push
`)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("project validate should accept remote_branch delivery, code=%d stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
	if !strings.Contains(stdout.String(), "lint_check name=project_package status=ok") {
		t.Fatalf("project validate should report ok, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
}

func TestProjectValidateRejectsInvalidRemoteBranchDeliveryConfig(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	writeSchedulerValidationProjectPackage(t, packageDir, `  delivery:
    mode: remote_branch
    base_branch: main
`)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project validate should reject missing remote, stdout=%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "invalid runtime.delivery") ||
		!strings.Contains(stdout.String(), "remote must be provided for remote_branch mode") {
		t.Fatalf("project validate should reject missing remote, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
}

func TestProjectValidateRejectsNonStringRemoteBranchDeliveryRemote(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	writeSchedulerValidationProjectPackage(t, packageDir, `  delivery:
    mode: remote_branch
    remote: 123
    base_branch: main
`)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project validate should reject non-string remote, stdout=%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "invalid runtime.delivery") ||
		!strings.Contains(stdout.String(), "remote must be a string") {
		t.Fatalf("project validate should reject non-string remote, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
}

func writeSchedulerValidationProjectPackage(t *testing.T, packageDir string, schedulerYAML string) {
	t.Helper()
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
` + schedulerYAML + `  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    review:
      skill: skills/review/default.md
      executor:
        command:
          - worker
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestProjectValidateRejectsUnknownRuntimePhase(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    experiments:
      commands:
        - task experiment
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project validate should reject unknown phase, stdout=%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "invalid runtime.phases") ||
		!strings.Contains(stdout.String(), "contains unknown phase: experiments") {
		t.Fatalf("project validate should reject unknown phase, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
}

func TestProjectValidateAcceptsRuntimePromptsConfig(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  prompts:
    system:
      file: prompts/system.md
    phases:
      implementation:
        prompt: prompts/implementation.md
        skills:
          - skills/testing-policy.md
      implementation_rework:
        prompt: prompts/implementation-rework.md
      decomposition:
        prompt: prompts/decomposition.md
        childDraftTemplate: prompts/decomposition-child-template.md
    repoSlots:
      app:
        phases:
          review:
            skills:
              - skills/app-review.md
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	for path, content := range map[string]string{
		"prompts/system.md":                       "system guidance",
		"prompts/implementation.md":               "implementation guidance",
		"skills/testing-policy.md":                "testing policy",
		"prompts/implementation-rework.md":        "rework guidance",
		"prompts/decomposition.md":                "decomposition guidance",
		"prompts/decomposition-child-template.md": "child template",
		"skills/app-review.md":                    "app review skill",
	} {
		target := filepath.Join(packageDir, path)
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(target, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("project validate should accept runtime.prompts, code=%d stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
	if !strings.Contains(stdout.String(), "lint_status=ok") {
		t.Fatalf("project validate should report ok, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
}

func TestProjectValidateAcceptsPromptsOnlyPhaseSkills(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  prompts:
    phases:
      implementation:
        prompt: prompts/implementation.md
      review:
        skills:
          - skills/review.md
  phases:
    implementation:
      executor:
        command:
          - worker
    review: {}
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	for path, content := range map[string]string{
		"prompts/implementation.md": "implementation guidance",
		"skills/review.md":          "review guidance",
	} {
		target := filepath.Join(packageDir, path)
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(target, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("project validate should accept prompts-only phase skills, code=%d stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
	if !strings.Contains(stdout.String(), "lint_status=ok") {
		t.Fatalf("project validate should report ok, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
}

func TestProjectValidateRejectsSkilllessPhaseWithoutPhasePrompt(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(filepath.Join(packageDir, "prompts"), 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  prompts:
    system:
      file: prompts/system.md
  phases:
    implementation:
      executor:
        command:
          - worker
    review: {}
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageDir, "prompts", "system.md"), []byte("system guidance"), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project validate should reject skillless implementation without a phase prompt, stdout=%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "invalid runtime.phases") ||
		!strings.Contains(stdout.String(), "implementation.skill must be provided") {
		t.Fatalf("project validate should reject skillless implementation, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
}

func TestProjectValidateRejectsSkilllessReviewWithoutPhasePrompt(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(filepath.Join(packageDir, "prompts"), 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  prompts:
    phases:
      implementation:
        prompt: prompts/implementation.md
  phases:
    implementation:
      executor:
        command:
          - worker
    review: {}
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageDir, "prompts", "implementation.md"), []byte("implementation guidance"), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project validate should reject skillless review without a phase prompt, stdout=%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "invalid runtime.phases") ||
		!strings.Contains(stdout.String(), "review.skill must be provided") {
		t.Fatalf("project validate should reject skillless review, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
}

func TestProjectValidateAcceptsDocsConfig(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	repoDir := filepath.Join(tempDir, "docs-repo")
	if err := os.MkdirAll(filepath.Join(repoDir, "docs", "architecture"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repoDir, "openapi.yaml"), []byte("openapi: 3.1.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ../app
  docs:
    path: ../docs-repo
docs:
  repoSlot: docs
  root: docs
  index: docs/README.md
  policy:
    missingRoot: create
  categories:
    architecture:
      path: docs/architecture
      index: docs/architecture/README.md
  languages:
    primary: ja
    secondary: [en]
  impactPolicy:
    defaultSeverity: warning
  authorities:
    openapi:
      source: openapi.yaml
      docs:
        - docs/api.md
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("project validate should accept docs config, code=%d stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
	if !strings.Contains(stdout.String(), "lint_status=ok") {
		t.Fatalf("project validate should report ok, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
}

func TestProjectValidateAcceptsMultiSurfaceDocsConfig(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	appDir := filepath.Join(tempDir, "app")
	libDir := filepath.Join(tempDir, "lib")
	docsDir := filepath.Join(tempDir, "docs")
	for _, dir := range []string{
		filepath.Join(appDir, "docs", "features"),
		filepath.Join(libDir, "docs", "shared-specs"),
		filepath.Join(libDir, "schema"),
		filepath.Join(docsDir, "docs", "interfaces"),
	} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(libDir, "schema", "greeting.json"), []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ../app
  lib:
    path: ../lib
  docs:
    path: ../docs
docs:
  surfaces:
    app:
      repoSlot: app
      root: docs
      categories:
        features:
          path: docs/features
    lib:
      repoSlot: lib
      root: docs
      categories:
        shared_specs:
          path: docs/shared-specs
    integrated:
      repoSlot: docs
      role: integration
      root: docs
      categories:
        interfaces:
          path: docs/interfaces
  authorities:
    greeting_schema:
      repoSlot: lib
      source: schema/greeting.json
      docs:
        - surface: lib
          path: docs/shared-specs/greeting-format.md
        - surface: integrated
          path: docs/interfaces/greeting-api.md
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("project validate should accept multi-surface docs config, code=%d stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
}

func TestProjectValidateRejectsInvalidDocsConfig(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ../app
docs:
  repoSlot: backend
  root: /docs
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project validate should reject invalid docs config, stdout=%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "invalid docs") ||
		!strings.Contains(stdout.String(), "repoSlot must match a repos entry: backend") {
		t.Fatalf("project validate should reject invalid docs config, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}

	repoDir := filepath.Join(tempDir, "app")
	outsideDir := filepath.Join(tempDir, "outside")
	if err := os.MkdirAll(filepath.Join(repoDir, "docs"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(outsideDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outsideDir, filepath.Join(repoDir, "docs", "outside")); err != nil {
		t.Fatal(err)
	}
	body = `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ../app
docs:
  root: docs
  index: docs/outside/new.md
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	stdout.Reset()
	stderr.Reset()
	code = run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project validate should reject intermediate symlink escape, stdout=%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "index must stay inside the docs repo slot") {
		t.Fatalf("project validate should reject intermediate symlink escape, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}

	body = `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ../app
  docs:
    path: ../docs
docs:
  surfaces:
    app:
      repoSlot: app
      root: docs
      categories:
        features:
          path: docs/features
  authorities:
    openapi:
      repoSlot: app
      source: spec/openapi.yaml
      docs:
        - surface: missing
          path: docs/api.md
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.MkdirAll(filepath.Join(repoDir, "spec"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repoDir, "spec", "openapi.yaml"), []byte("openapi: 3.1.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	stdout.Reset()
	stderr.Reset()
	code = run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project validate should reject unknown authority docs surface, stdout=%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "surface not found: missing") {
		t.Fatalf("project validate should reject unknown authority docs surface, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
}

func TestProjectValidateRejectsMissingRuntimePromptFile(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  prompts:
    phases:
      implementation:
        prompt: prompts/missing.md
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project validate should reject missing runtime prompt file, stdout=%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "invalid runtime.prompts") ||
		!strings.Contains(stdout.String(), "phases.implementation.prompt file not found: prompts/missing.md") {
		t.Fatalf("project validate should reject missing runtime prompt file, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
}

func TestProjectValidateRejectsRuntimePromptPathOutsidePackage(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  prompts:
    phases:
      implementation:
        prompt: ../outside.md
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project validate should reject outside runtime prompt path, stdout=%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "invalid runtime.prompts") ||
		!strings.Contains(stdout.String(), "phases.implementation.prompt must stay inside the project package root") {
		t.Fatalf("project validate should reject outside runtime prompt path, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
}

func TestProjectValidateRejectsRuntimePromptSymlinkOutsidePackage(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(filepath.Join(packageDir, "prompts"), 0o755); err != nil {
		t.Fatal(err)
	}
	outsidePath := filepath.Join(tempDir, "outside.md")
	if err := os.WriteFile(outsidePath, []byte("outside"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outsidePath, filepath.Join(packageDir, "prompts", "escape.md")); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  prompts:
    phases:
      implementation:
        prompt: prompts/escape.md
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project validate should reject outside runtime prompt symlink, stdout=%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "invalid runtime.prompts") ||
		!strings.Contains(stdout.String(), "phases.implementation.prompt must stay inside the project package root") {
		t.Fatalf("project validate should reject outside runtime prompt symlink, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
}

func TestProjectValidateRejectsMalformedRuntimePromptsConfig(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  prompts:
    phases:
      implementation:
        skills: not-an-array
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project validate should reject malformed runtime.prompts, stdout=%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "invalid runtime.prompts") ||
		!strings.Contains(stdout.String(), "phases.implementation.skills must be an array of non-empty strings") {
		t.Fatalf("project validate should reject malformed runtime.prompts, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
}

func TestProjectValidateRejectsInvalidRuntimePromptRepoSlotAddons(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(filepath.Join(packageDir, "skills"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageDir, "skills", "backend-review.md"), []byte("backend review"), 0o644); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  prompts:
    repoSlots:
      backend:
        phases:
          review:
            skills:
              - skills/backend-review.md
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project validate should reject unknown prompt repo slot, stdout=%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "invalid runtime.prompts") ||
		!strings.Contains(stdout.String(), "repoSlots.backend must match a repos entry") {
		t.Fatalf("project validate should reject unknown prompt repo slot, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
}

func TestProjectValidateRejectsUnsupportedRuntimePromptPhaseAndDuplicateSkills(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(filepath.Join(packageDir, "skills"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"deploy.md", "common.md"} {
		if err := os.WriteFile(filepath.Join(packageDir, "skills", name), []byte(name), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  prompts:
    repoSlots:
      app:
        phases:
          deployment:
            skills:
              - skills/deploy.md
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project validate should reject unsupported prompt phase, stdout=%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "repoSlots.app.phases.deployment is not a supported prompt phase") {
		t.Fatalf("project validate should reject unsupported prompt phase, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}

	body = `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  prompts:
    phases:
      review:
        skills:
          - skills/common.md
    repoSlots:
      app:
        phases:
          review:
            skills:
              - skills/common.md
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	stdout.Reset()
	stderr.Reset()
	code = run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project validate should reject duplicate repo-slot skill addon, stdout=%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "repoSlots.app.phases.review.skills duplicates phases.review.skills entry: skills/common.md") {
		t.Fatalf("project validate should reject duplicate repo-slot skill addon, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}

	body = `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  prompts:
    phases:
      implementation:
        skills:
          - skills/common.md
    repoSlots:
      app:
        phases:
          implementation_rework:
            skills:
              - skills/common.md
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	stdout.Reset()
	stderr.Reset()
	code = run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project validate should reject duplicate repo-slot rework skill addon, stdout=%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "repoSlots.app.phases.implementation_rework.skills duplicates phases.implementation.skills entry: skills/common.md") {
		t.Fatalf("project validate should reject duplicate repo-slot rework skill addon, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
}

func TestProjectValidateRejectsChildDraftTemplateOutsideDecomposition(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(filepath.Join(packageDir, "prompts"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageDir, "prompts", "review-child-template.md"), []byte("review template"), 0o644); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  prompts:
    phases:
      review:
        childDraftTemplate: prompts/review-child-template.md
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project validate should reject childDraftTemplate outside decomposition, stdout=%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "phases.review.childDraftTemplate is only supported for decomposition") {
		t.Fatalf("project validate should reject childDraftTemplate outside decomposition, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
}

func TestPromptPreviewShowsPromptLayersWithoutMutatingTask(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	writePromptPreviewProjectPackage(t, packageDir)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{
		"prompt", "preview",
		"--package", packageDir,
		"--phase", "decomposition",
		"--repo-slot", "app",
		"A2O#123",
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("prompt preview should pass, code=%d stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
	output := stdout.String()
	for _, want := range []string{
		"prompt_preview task_ref=A2O#123 phase=decomposition profile=decomposition",
		"prompt_preview_repo_slots slots=app status=selected",
		"kind=project_system_prompt",
		"kind=project_phase_prompt",
		"kind=project_phase_skill",
		"kind=decomposition_child_draft_template",
		"kind=repo_slot_phase_prompt",
		"kind=repo_slot_decomposition_child_draft_template",
		"kind=task_runtime_data",
		"task_ref=A2O#123",
		"--- prompt_composed_instruction ---",
		"prompt_preview_status=ok mutation=none",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("prompt preview missing %q in:\n%s", want, output)
		}
	}
}

func TestPromptPreviewComposesMultipleRepoSlotsInFlagOrder(t *testing.T) {
	for _, tt := range []struct {
		name string
		args []string
	}{
		{
			name: "repeated flags",
			args: []string{"--repo-slot", "app", "--repo-slot", "lib"},
		},
		{
			name: "comma separated",
			args: []string{"--repo-slot", "app,lib"},
		},
	} {
		t.Run(tt.name, func(t *testing.T) {
			tempDir := t.TempDir()
			packageDir := filepath.Join(tempDir, "package")
			writePromptPreviewProjectPackage(t, packageDir)

			var stdout bytes.Buffer
			var stderr bytes.Buffer
			args := append([]string{
				"prompt", "preview",
				"--package", packageDir,
				"--phase", "decomposition",
			}, tt.args...)
			args = append(args, "A2O#123")
			code := run(args, &fakeRunner{}, &stdout, &stderr)
			if code != 0 {
				t.Fatalf("multi repo prompt preview should pass, code=%d stdout=%s stderr=%s", code, stdout.String(), stderr.String())
			}
			output := stdout.String()
			for _, want := range []string{
				"prompt_preview_repo_slots slots=app,lib status=selected",
				"kind=repo_slot_phase_prompt title=prompts/app-decomposition.md",
				"detail=app profile=decomposition",
				"kind=repo_slot_phase_prompt title=prompts/lib-decomposition.md",
				"detail=lib profile=decomposition",
				"kind=repo_slot_decomposition_child_draft_template title=prompts/app-child-template.md",
				"kind=repo_slot_decomposition_child_draft_template title=prompts/lib-child-template.md",
			} {
				if !strings.Contains(output, want) {
					t.Fatalf("multi repo prompt preview missing %q in:\n%s", want, output)
				}
			}
			appIndex := strings.Index(output, "title=prompts/app-decomposition.md")
			libIndex := strings.Index(output, "title=prompts/lib-decomposition.md")
			if appIndex < 0 || libIndex < 0 || appIndex > libIndex {
				t.Fatalf("multi repo prompt preview did not preserve repo-slot flag order:\n%s", output)
			}
		})
	}
}

func TestPromptPreviewUsesParentReviewCoreSkill(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(filepath.Join(packageDir, "prompts"), 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  prompts:
    phases:
      parent_review:
        prompt: prompts/parent-review.md
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    review:
      skill: skills/review/default.md
      executor:
        command:
          - worker
    parent_review:
      skill: skills/review/parent.md
      executor:
        command:
          - worker
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageDir, "prompts", "parent-review.md"), []byte("parent review guidance"), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{
		"prompt", "preview",
		"--package", packageDir,
		"--phase", "review",
		"--task-kind", "parent",
		"A2O#123",
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("parent review prompt preview should pass, code=%d stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
	output := stdout.String()
	for _, want := range []string{
		"prompt_preview task_ref=A2O#123 phase=review profile=parent_review",
		"detail=source=runtime.phases.parent_review.skill",
		"skills/review/parent.md",
		"kind=project_phase_prompt",
		"kind=ticket_phase_instruction",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("parent review prompt preview missing %q in:\n%s", want, output)
		}
	}
}

func TestPromptPreviewFallsBackImplementationReworkBasePrompt(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(filepath.Join(packageDir, "prompts"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(packageDir, "skills"), 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  prompts:
    phases:
      implementation:
        prompt: prompts/implementation.md
        skills:
          - skills/implementation-policy.md
    repoSlots:
      app:
        phases:
          implementation_rework:
            prompt: prompts/app-rework.md
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	for path, content := range map[string]string{
		"prompts/implementation.md":       "implementation guidance",
		"skills/implementation-policy.md": "implementation policy",
		"prompts/app-rework.md":           "app rework addon",
	} {
		if err := os.WriteFile(filepath.Join(packageDir, path), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{
		"prompt", "preview",
		"--package", packageDir,
		"--phase", "implementation",
		"--prior-review-feedback",
		"--repo-slot", "app",
		"A2O#123",
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("implementation rework prompt preview should pass, code=%d stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
	output := stdout.String()
	for _, want := range []string{
		"prompt_preview task_ref=A2O#123 phase=implementation profile=implementation_rework",
		"kind=project_phase_prompt title=prompts/implementation.md",
		"detail=profile=implementation",
		"kind=project_phase_skill title=skills/implementation-policy.md",
		"kind=repo_slot_phase_prompt title=prompts/app-rework.md",
		"detail=app profile=implementation_rework",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("implementation rework prompt preview missing %q in:\n%s", want, output)
		}
	}
}

func TestDoctorPromptsReportsInvalidPromptConfig(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  prompts:
    phases:
      implementation:
        prompt: prompts/missing.md
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"doctor", "prompts", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("doctor prompts should fail for invalid prompt config")
	}
	output := stdout.String()
	for _, want := range []string{
		"prompt_doctor_check name=project_package status=blocked",
		"invalid runtime.prompts",
		"phases.implementation.prompt file not found: prompts/missing.md",
		"prompt_doctor_status=blocked",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("doctor prompts missing %q in stdout=%s stderr=%s", want, stdout.String(), stderr.String())
		}
	}
}

func writePromptPreviewProjectPackage(t *testing.T, packageDir string) {
	t.Helper()
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
  lib:
    path: ..
runtime:
  prompts:
    system:
      file: prompts/system.md
    phases:
      decomposition:
        prompt: prompts/decomposition.md
        skills:
          - skills/decomposition-policy.md
        childDraftTemplate: prompts/decomposition-child-template.md
    repoSlots:
      app:
        phases:
          decomposition:
            prompt: prompts/app-decomposition.md
            childDraftTemplate: prompts/app-child-template.md
      lib:
        phases:
          decomposition:
            prompt: prompts/lib-decomposition.md
            childDraftTemplate: prompts/lib-child-template.md
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    merge:
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	for path, content := range map[string]string{
		"prompts/system.md":                       "system guidance",
		"prompts/decomposition.md":                "decomposition guidance",
		"skills/decomposition-policy.md":          "decomposition policy",
		"prompts/decomposition-child-template.md": "base child template",
		"prompts/app-decomposition.md":            "app decomposition guidance",
		"prompts/app-child-template.md":           "app child template",
		"prompts/lib-decomposition.md":            "lib decomposition guidance",
		"prompts/lib-child-template.md":           "lib child template",
	} {
		target := filepath.Join(packageDir, path)
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(target, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}
