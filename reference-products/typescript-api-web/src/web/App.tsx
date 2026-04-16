import { nextDispatchCandidate, seedWorkOrders, summarizeSchedule } from "../domain/work-orders";

export function App() {
  const summary = summarizeSchedule(seedWorkOrders);
  const candidate = nextDispatchCandidate(seedWorkOrders);

  return (
    <main>
      <h1>Field Queue</h1>
      <p>Ready work: {summary.readyCount}</p>
      <p>Urgent work: {summary.urgentCount}</p>
      <p>Total estimate: {summary.totalMinutes} minutes</p>
      <section>
        <h2>Next dispatch</h2>
        <p>{candidate ? `${candidate.customer} (${candidate.id})` : "No queued work"}</p>
      </section>
    </main>
  );
}
