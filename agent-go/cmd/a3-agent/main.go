package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/wamukat/a3-engine/agent-go/internal/agent"
)

func main() {
	agentName := flag.String("agent", envDefault("A3_AGENT_NAME", "local-agent"), "agent name used when polling the A3 control plane")
	controlPlaneURL := flag.String("control-plane-url", envDefault("A3_CONTROL_PLANE_URL", "http://127.0.0.1:7393"), "A3 control plane base URL")
	workspaceRoot := flag.String("workspace-root", envDefault("A3_AGENT_WORKSPACE_ROOT", ""), "agent-owned workspace root for materialized jobs")
	sourceAliases := sourceAliasFlag(parseSourceAliases(os.Getenv("A3_AGENT_SOURCE_ALIASES")))
	flag.Var(&sourceAliases, "source-alias", "source alias mapping for materialized jobs, in name=path form; repeatable")
	flag.Parse()

	client := agent.HTTPClient{BaseURL: *controlPlaneURL}
	worker := agent.Worker{
		AgentName: *agentName,
		Client:    client,
	}
	if *workspaceRoot != "" || len(sourceAliases) > 0 {
		worker.Materializer = agent.WorkspaceMaterializer{
			WorkspaceRoot: *workspaceRoot,
			SourceAliases: map[string]string(sourceAliases),
		}
	}
	result, idle, err := worker.RunOnce()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if idle {
		fmt.Println("agent idle")
		return
	}
	fmt.Printf("agent completed %s status=%s\n", result.JobID, result.Status)
}

type sourceAliasFlag map[string]string

func (f *sourceAliasFlag) String() string {
	if f == nil {
		return ""
	}
	pairs := make([]string, 0, len(*f))
	for key, value := range *f {
		pairs = append(pairs, key+"="+value)
	}
	return strings.Join(pairs, ",")
}

func (f *sourceAliasFlag) Set(value string) error {
	key, path, ok := strings.Cut(value, "=")
	if !ok || key == "" || path == "" {
		return fmt.Errorf("source alias must be name=path")
	}
	if *f == nil {
		*f = sourceAliasFlag{}
	}
	(*f)[key] = path
	return nil
}

func parseSourceAliases(value string) map[string]string {
	aliases := map[string]string{}
	for _, item := range strings.Split(value, ",") {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		key, path, ok := strings.Cut(item, "=")
		if ok && key != "" && path != "" {
			aliases[key] = path
		}
	}
	return aliases
}

func envDefault(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
