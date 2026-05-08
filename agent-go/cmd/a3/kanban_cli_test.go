package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestKanbanCLITransitionClearsResolvedWhenLeavingDone(t *testing.T) {
	var transitionPayload map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/tickets/7":
			_, _ = w.Write([]byte(`{"id":7,"boardId":2,"laneId":14,"title":"Done task","bodyMarkdown":"","isResolved":true,"isArchived":false,"priority":2,"position":0,"ref":"A2O#7","shortRef":"#7","tags":[],"comments":[]}`))
		case r.Method == http.MethodGet && r.URL.Path == "/api/boards/2":
			_, _ = w.Write([]byte(`{"board":{"id":2,"name":"A2O"},"lanes":[{"id":10,"name":"In progress","position":2},{"id":14,"name":"Done","position":6}],"tags":[]}`))
		case r.Method == http.MethodPatch && r.URL.Path == "/api/tickets/7/transition":
			if err := json.NewDecoder(r.Body).Decode(&transitionPayload); err != nil {
				t.Fatalf("decode transition payload: %v", err)
			}
			_, _ = w.Write([]byte(`{"id":7,"boardId":2,"laneId":10,"title":"Done task","bodyMarkdown":"","isResolved":false,"isArchived":false,"priority":2,"position":0,"ref":"A2O#7","shortRef":"#7"}`))
		case r.Method == http.MethodGet && r.URL.Path == "/api/tickets/7/relations":
			_, _ = w.Write([]byte(`{"children":[],"blockers":[],"blockedBy":[],"related":[]}`))
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	err := runKanbanCLI([]string{
		"--base-url", server.URL,
		"task-transition",
		"--task-id", "7",
		"--status", "In progress",
	}, &stdout, &stderr)
	if err != nil {
		t.Fatalf("runKanbanCLI error=%v stderr=%s", err, stderr.String())
	}
	if got := transitionPayload["isResolved"]; got != false {
		t.Fatalf("transition isResolved=%v, want false payload=%v", got, transitionPayload)
	}
}

func TestKanbanCLIAcceptsPythonCompatibilityFlagsAndCommands(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/boards":
			_, _ = w.Write([]byte(`{"boards":[{"id":2,"name":"A2O"}]}`))
		case r.Method == http.MethodGet && r.URL.Path == "/api/boards/2":
			_, _ = w.Write([]byte(`{"board":{"id":2,"name":"A2O"},"lanes":[{"id":9,"name":"To do","position":1},{"id":10,"name":"In progress","position":2}],"tags":[{"id":3,"name":"repo:app","color":"#888888"}]}`))
		case r.Method == http.MethodGet && r.URL.Path == "/api/boards/2/tags":
			_, _ = w.Write([]byte(`{"tags":[{"id":3,"name":"repo:app","color":"#888888"}]}`))
		case r.Method == http.MethodDelete && r.URL.Path == "/api/tags/3":
			w.WriteHeader(http.StatusNoContent)
		case r.Method == http.MethodPost && r.URL.Path == "/api/boards/2/tickets":
			_, _ = w.Write([]byte(`{"id":8,"boardId":2,"laneId":9,"title":"Created","bodyMarkdown":"Body","isResolved":false,"isArchived":false,"priority":2,"position":0,"ref":"A2O#8","shortRef":"#8"}`))
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()

	cases := [][]string{
		{"--base-url", server.URL, "label-delete", "--project", "A2O", "--label", "repo:app"},
		{"--base-url", server.URL, "task-create", "--project", "A2O", "--title", "Created", "--description", "Body", "--reference", "A2O#custom"},
	}
	for _, args := range cases {
		var stdout bytes.Buffer
		var stderr bytes.Buffer
		if err := runKanbanCLI(args, &stdout, &stderr); err != nil {
			t.Fatalf("runKanbanCLI(%s) error=%v stderr=%s", strings.Join(args, " "), err, stderr.String())
		}
	}
}

func TestKanbanCLIReordersTask(t *testing.T) {
	var reorderPayload map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/tickets/8":
			_, _ = w.Write([]byte(`{"id":8,"boardId":2,"laneId":9,"title":"Move me","bodyMarkdown":"","isResolved":false,"isArchived":false,"priority":2,"position":1,"ref":"A2O#8","shortRef":"#8","tags":[],"comments":[]}`))
		case r.Method == http.MethodGet && r.URL.Path == "/api/boards/2":
			_, _ = w.Write([]byte(`{"board":{"id":2,"name":"A2O"},"lanes":[{"id":9,"name":"To do","position":1},{"id":10,"name":"In progress","position":2}],"tags":[]}`))
		case r.Method == http.MethodGet && r.URL.Path == "/api/boards/2/tickets":
			_, _ = w.Write([]byte(`{"tickets":[{"id":7,"boardId":2,"laneId":10,"title":"Other","bodyMarkdown":"","isResolved":false,"isArchived":false,"priority":2,"position":0,"ref":"A2O#7","shortRef":"#7"},{"id":8,"boardId":2,"laneId":9,"title":"Move me","bodyMarkdown":"","isResolved":false,"isArchived":false,"priority":2,"position":1,"ref":"A2O#8","shortRef":"#8"}]}`))
		case r.Method == http.MethodPost && r.URL.Path == "/api/boards/2/tickets/reorder":
			if err := json.NewDecoder(r.Body).Decode(&reorderPayload); err != nil {
				t.Fatalf("decode reorder payload: %v", err)
			}
			_, _ = w.Write([]byte(`{"tickets":[{"id":8,"boardId":2,"laneId":10,"title":"Move me","bodyMarkdown":"","isResolved":false,"isArchived":false,"priority":2,"position":0,"ref":"A2O#8","shortRef":"#8"},{"id":7,"boardId":2,"laneId":10,"title":"Other","bodyMarkdown":"","isResolved":false,"isArchived":false,"priority":2,"position":1,"ref":"A2O#7","shortRef":"#7"}]}`))
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	err := runKanbanCLI([]string{
		"--base-url", server.URL,
		"task-reorder",
		"--task-id", "8",
		"--status", "In progress",
		"--position", "0",
	}, &stdout, &stderr)
	if err != nil {
		t.Fatalf("runKanbanCLI error=%v stderr=%s", err, stderr.String())
	}
	items, ok := reorderPayload["items"].([]any)
	if !ok || len(items) == 0 {
		t.Fatalf("reorder items missing: %v", reorderPayload)
	}
	first := items[0].(map[string]any)
	if intValue(first["ticketId"]) != 8 || intValue(first["laneId"]) != 10 || intValue(first["position"]) != 0 {
		t.Fatalf("first reorder item=%v, want ticket 8 lane 10 position 0", first)
	}
}
