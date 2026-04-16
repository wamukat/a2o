package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"

	"example.com/a2o/reference/go-api-cli/internal/inventory"
)

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"ok": true, "service": "go-api-cli"})
	})
	mux.HandleFunc("/items", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"items": inventory.SeedItems, "summary": inventory.Summarize(inventory.SeedItems)})
	})
	mux.HandleFunc("/reorder", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"items": inventory.ReorderCandidates(inventory.SeedItems)})
	})

	addr := env("REFAPI_ADDR", "127.0.0.1:4020")
	log.Printf("go-api-cli listening on http://%s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}

func writeJSON(w http.ResponseWriter, payload any) {
	w.Header().Set("content-type", "application/json; charset=utf-8")
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func env(key, fallback string) string {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	return value
}
