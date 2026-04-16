package inventory

import "sort"

type Item struct {
	SKU       string `json:"sku"`
	Name      string `json:"name"`
	OnHand    int    `json:"onHand"`
	ReorderAt int    `json:"reorderAt"`
}

type Summary struct {
	TotalItems   int `json:"totalItems"`
	ReorderCount int `json:"reorderCount"`
}

var SeedItems = []Item{
	{SKU: "kit-001", Name: "Starter Kit", OnHand: 12, ReorderAt: 5},
	{SKU: "cable-010", Name: "Field Cable", OnHand: 2, ReorderAt: 6},
	{SKU: "sensor-020", Name: "Door Sensor", OnHand: 7, ReorderAt: 4},
}

func Summarize(items []Item) Summary {
	summary := Summary{TotalItems: len(items)}
	for _, item := range items {
		if item.OnHand <= item.ReorderAt {
			summary.ReorderCount++
		}
	}
	return summary
}

func ReorderCandidates(items []Item) []Item {
	candidates := make([]Item, 0)
	for _, item := range items {
		if item.OnHand <= item.ReorderAt {
			candidates = append(candidates, item)
		}
	}

	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].OnHand == candidates[j].OnHand {
			return candidates[i].SKU < candidates[j].SKU
		}
		return candidates[i].OnHand < candidates[j].OnHand
	})

	return candidates
}
