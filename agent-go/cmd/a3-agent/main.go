package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/wamukat/a3-engine/agent-go/internal/agent"
)

func main() {
	agentName := flag.String("agent", envDefault("A3_AGENT_NAME", "local-agent"), "agent name used when polling the A3 control plane")
	controlPlaneURL := flag.String("control-plane-url", envDefault("A3_CONTROL_PLANE_URL", "http://127.0.0.1:7393"), "A3 control plane base URL")
	flag.Parse()

	client := agent.HTTPClient{BaseURL: *controlPlaneURL}
	result, idle, err := agent.Worker{
		AgentName: *agentName,
		Client:    client,
	}.RunOnce()
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

func envDefault(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
