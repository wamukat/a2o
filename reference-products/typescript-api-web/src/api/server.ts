import { createServer } from "node:http";
import { nextDispatchCandidate, seedWorkOrders, summarizeSchedule } from "../domain/work-orders";

const port = Number(process.env.PORT ?? 4010);

const server = createServer((request, response) => {
  response.setHeader("content-type", "application/json; charset=utf-8");

  if (request.url === "/health") {
    response.end(JSON.stringify({ ok: true, service: "typescript-api-web" }));
    return;
  }

  if (request.url === "/work-orders") {
    response.end(JSON.stringify({ items: seedWorkOrders, summary: summarizeSchedule(seedWorkOrders) }));
    return;
  }

  if (request.url === "/dispatch-candidate") {
    response.end(JSON.stringify({ item: nextDispatchCandidate(seedWorkOrders) ?? null }));
    return;
  }

  response.statusCode = 404;
  response.end(JSON.stringify({ error: "not_found" }));
});

server.listen(port, "127.0.0.1", () => {
  console.log(`typescript-api-web listening on http://127.0.0.1:${port}`);
});
