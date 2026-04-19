package main

import (
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type lintSeverity int

const (
	lintOK lintSeverity = iota
	lintWarning
	lintBlocked
)

func runProjectLint(args []string, stdout io.Writer, stderr io.Writer) int {
	flags := flag.NewFlagSet("a2o project lint", flag.ContinueOnError)
	flags.SetOutput(stderr)
	packagePath := flags.String("package", "", "project package directory")
	workspaceRoot := flags.String("workspace", ".", "workspace root used when discovering ./a2o-project or ./project-package")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if flags.NArg() != 0 {
		printUserFacingError(stderr, fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " ")))
		return 2
	}
	absWorkspaceRoot, err := filepath.Abs(*workspaceRoot)
	if err != nil {
		printUserFacingError(stderr, fmt.Errorf("resolve workspace root: %w", err))
		return 1
	}
	resolvedPackagePath, err := resolveBootstrapPackagePath(*packagePath, absWorkspaceRoot)
	if err != nil {
		printUserFacingError(stderr, err)
		return 1
	}
	absPackagePath, err := filepath.Abs(resolvedPackagePath)
	if err != nil {
		printUserFacingError(stderr, fmt.Errorf("resolve package path: %w", err))
		return 1
	}

	status := lintOK
	report := func(name string, severity lintSeverity, detail string, action string) {
		if severity > status {
			status = severity
		}
		fmt.Fprintf(stdout, "lint_check name=%s status=%s detail=%s action=%s\n", name, lintStatusName(severity), singleLine(detail), singleLine(action))
	}

	config, err := loadProjectPackageConfig(absPackagePath)
	if err != nil {
		report("project_package", lintBlocked, err.Error(), "fix project.yaml or rerun a2o project template")
		fmt.Fprintf(stdout, "lint_status=%s\n", lintStatusName(status))
		return 1
	}
	report("project_package", lintOK, "project.yaml schema_version="+config.SchemaVersion+" package="+config.PackageName, "none")
	checkProjectScriptContract(absPackagePath, func(name string, ok bool, detail string, action string) {
		severity := lintOK
		if !ok {
			severity = lintBlocked
		}
		report(name, severity, detail, action)
	})
	checkProjectFixtureReferences(absPackagePath, report)
	checkProjectUnusedCommands(absPackagePath, report)

	fmt.Fprintf(stdout, "lint_status=%s\n", lintStatusName(status))
	if status == lintBlocked {
		return 1
	}
	return 0
}

func lintStatusName(status lintSeverity) string {
	switch status {
	case lintBlocked:
		return "blocked"
	case lintWarning:
		return "warning"
	default:
		return "ok"
	}
}

func checkProjectFixtureReferences(packagePath string, report func(string, lintSeverity, string, string)) {
	findings := []string{}
	projectFile := filepath.Join(packagePath, "project.yaml")
	body, err := os.ReadFile(projectFile)
	if err != nil {
		report("fixture_reference", lintBlocked, err.Error(), "inspect project.yaml")
		return
	}
	for _, finding := range fixtureReferenceFindings("project.yaml", string(body)) {
		findings = append(findings, finding)
	}

	commandsDir := filepath.Join(packagePath, "commands")
	_ = filepath.WalkDir(commandsDir, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry == nil || entry.IsDir() {
			return nil
		}
		name := strings.ToLower(entry.Name())
		if strings.Contains(name, "dummy") || strings.Contains(name, "fixture") || strings.Contains(name, "fake") {
			rel, _ := filepath.Rel(packagePath, path)
			findings = append(findings, filepath.ToSlash(rel)+":fixture-like command name")
		}
		return nil
	})
	if len(findings) > 0 {
		sort.Strings(findings)
		report("fixture_reference", lintBlocked, strings.Join(findings, ","), "move deterministic test workers under tests/fixtures and keep production project.yaml on production commands")
		return
	}
	report("fixture_reference", lintOK, "no production config fixture references", "none")
}

func fixtureReferenceFindings(label string, text string) []string {
	findings := []string{}
	normalized := strings.ReplaceAll(text, "\\", "/")
	for _, marker := range []string{"tests/fixtures", "test/fixtures"} {
		if strings.Contains(normalized, marker) {
			findings = append(findings, label+":"+marker)
		}
	}
	for _, marker := range []string{"dummy-worker", "fixture-worker", "fake-worker"} {
		if strings.Contains(strings.ToLower(normalized), marker) {
			findings = append(findings, label+":"+marker)
		}
	}
	return findings
}

func checkProjectUnusedCommands(packagePath string, report func(string, lintSeverity, string, string)) {
	commandsDir := filepath.Join(packagePath, "commands")
	if info, err := os.Stat(commandsDir); err != nil || !info.IsDir() {
		report("unused_commands", lintOK, "commands directory not present", "none")
		return
	}
	referenceText := projectPackageReferenceText(packagePath)
	unused := []string{}
	_ = filepath.WalkDir(commandsDir, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry == nil || entry.IsDir() {
			return nil
		}
		info, err := entry.Info()
		if err != nil || !info.Mode().IsRegular() {
			return nil
		}
		rel, _ := filepath.Rel(packagePath, path)
		rel = filepath.ToSlash(rel)
		name := entry.Name()
		if !strings.Contains(referenceText, rel) && !strings.Contains(referenceText, name) {
			unused = append(unused, rel)
		}
		return nil
	})
	if len(unused) > 0 {
		sort.Strings(unused)
		report("unused_commands", lintWarning, strings.Join(unused, ","), "remove unused commands or document them in package README/skills/task templates")
		return
	}
	report("unused_commands", lintOK, "all commands are referenced by package docs or config", "none")
}

func projectPackageReferenceText(packagePath string) string {
	parts := []string{}
	_ = filepath.WalkDir(packagePath, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry == nil {
			return nil
		}
		if entry.IsDir() {
			switch entry.Name() {
			case ".git", ".work", "commands", "node_modules", "vendor", "target", "dist", "build":
				if path != packagePath {
					return filepath.SkipDir
				}
			}
			return nil
		}
		if !isReferenceTextFile(path) {
			return nil
		}
		body, err := os.ReadFile(path)
		if err == nil {
			parts = append(parts, string(body))
		}
		return nil
	})
	return strings.Join(parts, "\n")
}

func isReferenceTextFile(path string) bool {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".yaml", ".yml", ".md", ".markdown", ".txt", ".rst", ".adoc":
		return true
	default:
		return false
	}
}
