package errorpolicy

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

type workerCase struct {
	Name          string `json:"name"`
	Summary       string `json:"summary"`
	ObservedState string `json:"observed_state"`
	Phase         string `json:"phase"`
	Category      string `json:"category"`
}

type fixtures struct {
	WorkerCases []workerCase `json:"worker_cases"`
}

func TestWorkerCategoryMatchesSharedContractCases(t *testing.T) {
	body, err := os.ReadFile(filepath.Join("..", "..", "..", "testdata", "error_category_cases.json"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var fixture fixtures
	if err := json.Unmarshal(body, &fixture); err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	for _, tt := range fixture.WorkerCases {
		t.Run(tt.Name, func(t *testing.T) {
			if got := WorkerCategory(tt.Summary, tt.ObservedState, tt.Phase); got != tt.Category {
				t.Fatalf("WorkerCategory() = %q, want %q", got, tt.Category)
			}
			if remediation := WorkerRemediation(tt.Category); remediation == "" {
				t.Fatal("WorkerRemediation() should not be empty")
			}
		})
	}
}
