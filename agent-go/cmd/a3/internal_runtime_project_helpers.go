package main

import "strings"

func runtimeProjectCommandArg(projectKey string, multiProjectMode bool) string {
	trimmed := strings.TrimSpace(projectKey)
	if !multiProjectMode || trimmed == "" {
		return ""
	}
	return " --project " + trimmed
}
