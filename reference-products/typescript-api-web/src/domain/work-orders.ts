export type WorkOrderStatus = "queued" | "scheduled" | "blocked" | "done";

export interface WorkOrder {
  id: string;
  customer: string;
  priority: "low" | "normal" | "urgent";
  status: WorkOrderStatus;
  estimateMinutes: number;
}

export interface ScheduleSummary {
  totalMinutes: number;
  urgentCount: number;
  readyCount: number;
}

export const seedWorkOrders: WorkOrder[] = [
  {
    id: "wo-1001",
    customer: "North Clinic",
    priority: "urgent",
    status: "queued",
    estimateMinutes: 45
  },
  {
    id: "wo-1002",
    customer: "Harbor Foods",
    priority: "normal",
    status: "scheduled",
    estimateMinutes: 90
  },
  {
    id: "wo-1003",
    customer: "Cedar School",
    priority: "low",
    status: "blocked",
    estimateMinutes: 30
  }
];

export function summarizeSchedule(workOrders: WorkOrder[]): ScheduleSummary {
  return workOrders.reduce<ScheduleSummary>(
    (summary, order) => ({
      totalMinutes: summary.totalMinutes + order.estimateMinutes,
      urgentCount: summary.urgentCount + (order.priority === "urgent" ? 1 : 0),
      readyCount:
        summary.readyCount + (order.status === "queued" || order.status === "scheduled" ? 1 : 0)
    }),
    { totalMinutes: 0, urgentCount: 0, readyCount: 0 }
  );
}

export function nextDispatchCandidate(workOrders: WorkOrder[]): WorkOrder | undefined {
  const weight = { urgent: 0, normal: 1, low: 2 };

  return workOrders
    .filter((order) => order.status === "queued")
    .sort((left, right) => weight[left.priority] - weight[right.priority] || left.id.localeCompare(right.id))[0];
}
