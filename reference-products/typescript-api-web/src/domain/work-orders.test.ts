import { describe, expect, it } from "vitest";
import { nextDispatchCandidate, summarizeSchedule, type WorkOrder } from "./work-orders";

describe("work order scheduling", () => {
  it("summarizes ready and urgent work", () => {
    const orders: WorkOrder[] = [
      { id: "a", customer: "A", priority: "urgent", status: "queued", estimateMinutes: 10 },
      { id: "b", customer: "B", priority: "normal", status: "done", estimateMinutes: 20 }
    ];

    expect(summarizeSchedule(orders)).toEqual({
      totalMinutes: 30,
      urgentCount: 1,
      readyCount: 1
    });
  });

  it("chooses the highest priority queued work order", () => {
    const orders: WorkOrder[] = [
      { id: "b", customer: "B", priority: "normal", status: "queued", estimateMinutes: 20 },
      { id: "a", customer: "A", priority: "urgent", status: "queued", estimateMinutes: 10 }
    ];

    expect(nextDispatchCandidate(orders)?.id).toBe("a");
  });
});
