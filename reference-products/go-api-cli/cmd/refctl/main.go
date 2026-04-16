package main

import (
	"encoding/json"
	"fmt"
	"os"

	"example.com/a2o/reference/go-api-cli/internal/inventory"
)

func main() {
	command := "summary"
	if len(os.Args) > 1 {
		command = os.Args[1]
	}

	switch command {
	case "summary":
		printJSON(inventory.Summarize(inventory.SeedItems))
	case "reorder":
		printJSON(inventory.ReorderCandidates(inventory.SeedItems))
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n", command)
		os.Exit(2)
	}
}

func printJSON(value any) {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		fmt.Fprintf(os.Stderr, "encode json: %v\n", err)
		os.Exit(1)
	}
}
