package inventory

import "testing"

func TestSummarize(t *testing.T) {
	items := []Item{
		{SKU: "a", OnHand: 1, ReorderAt: 2},
		{SKU: "b", OnHand: 5, ReorderAt: 2},
	}

	got := Summarize(items)
	if got.TotalItems != 2 || got.ReorderCount != 1 {
		t.Fatalf("unexpected summary: %+v", got)
	}
}

func TestReorderCandidates(t *testing.T) {
	items := []Item{
		{SKU: "b", OnHand: 4, ReorderAt: 8},
		{SKU: "a", OnHand: 1, ReorderAt: 2},
	}

	got := ReorderCandidates(items)
	if len(got) != 2 {
		t.Fatalf("expected two candidates, got %d", len(got))
	}
	if got[0].SKU != "a" {
		t.Fatalf("expected lowest stock first, got %s", got[0].SKU)
	}
}
