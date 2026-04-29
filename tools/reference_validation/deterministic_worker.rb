#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"

request_path = Pathname(ENV.fetch("A2O_WORKER_REQUEST_PATH"))
result_path = Pathname(ENV.fetch("A2O_WORKER_RESULT_PATH"))
request = JSON.parse(request_path.read)

def write(path, content)
  Pathname(path).write(content)
end

def append_once(path, marker, content)
  current = Pathname(path).read
  return if current.include?(marker)

  Pathname(path).write(current + content)
end

def slot_root(request, slot)
  Pathname(request.fetch("slot_paths").fetch(slot))
end

def editable_slot?(request, slot)
  request.fetch("scope_snapshot", {}).fetch("edit_scope", request.fetch("slot_paths").keys).include?(slot)
end

def success(request, summary:, changed_files: {}, repo_scope: nil)
  payload = {
    "task_ref" => request.fetch("task_ref"),
    "run_ref" => request.fetch("run_ref"),
    "phase" => request.fetch("phase"),
    "success" => true,
    "summary" => summary,
    "failing_command" => nil,
    "observed_state" => nil,
    "rework_required" => false
  }
  if request.fetch("phase") == "implementation"
    scope = repo_scope || changed_files.keys.first || request.fetch("slot_paths").keys.first
    payload["changed_files"] = changed_files
    payload["review_disposition"] = {
      "kind" => "completed",
      "repo_scope" => scope,
      "summary" => "deterministic implementation self-review clean",
      "description" => "Reference validation worker applied the requested baseline change.",
      "finding_key" => "reference-validation-clean"
    }
  elsif request.fetch("phase") == "review"
    payload["review_disposition"] = {
      "kind" => "completed",
      "repo_scope" => repo_scope || "both",
      "summary" => "deterministic parent review clean",
      "description" => "Reference validation worker found no parent aggregation findings.",
      "finding_key" => "reference-validation-parent-clean"
    }
  end
  payload
end

def fail_payload(request, error)
  {
    "task_ref" => request.fetch("task_ref"),
    "run_ref" => request.fetch("run_ref"),
    "phase" => request.fetch("phase"),
    "success" => false,
    "summary" => "deterministic reference worker failed",
    "failing_command" => "tools/reference_validation/deterministic_worker.rb",
    "observed_state" => "#{error.class}: #{error.message}",
    "rework_required" => false,
    "diagnostics" => { "backtrace" => Array(error.backtrace).first(8) }
  }
end

def implement_typescript(root)
  write(
    root.join("src/domain/work-orders.ts"),
    <<~TS
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

      export function filterWorkOrdersByStatus(workOrders: WorkOrder[], status: WorkOrderStatus): WorkOrder[] {
        return workOrders.filter((order) => order.status === status);
      }

      export function nextDispatchCandidate(workOrders: WorkOrder[]): WorkOrder | undefined {
        const weight = { urgent: 0, normal: 1, low: 2 };

        return workOrders
          .filter((order) => order.status === "queued")
          .sort((left, right) => weight[left.priority] - weight[right.priority] || left.id.localeCompare(right.id))[0];
      }
    TS
  )
  write(
    root.join("src/api/server.ts"),
    <<~TS
      import { createServer } from "node:http";
      import { filterWorkOrdersByStatus, nextDispatchCandidate, seedWorkOrders, summarizeSchedule, type WorkOrderStatus } from "../domain/work-orders";

      const port = Number(process.env.PORT ?? 4010);
      const statuses = new Set<WorkOrderStatus>(["queued", "scheduled", "blocked", "done"]);

      const server = createServer((request, response) => {
        response.setHeader("content-type", "application/json; charset=utf-8");

        if (request.url === "/health") {
          response.end(JSON.stringify({ ok: true, service: "typescript-api-web" }));
          return;
        }

        if (request.url?.startsWith("/work-orders")) {
          const url = new URL(request.url, "http://127.0.0.1");
          const status = url.searchParams.get("status") as WorkOrderStatus | null;
          const items = status && statuses.has(status) ? filterWorkOrdersByStatus(seedWorkOrders, status) : seedWorkOrders;
          response.end(JSON.stringify({ items, summary: summarizeSchedule(items) }));
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
    TS
  )
  write(
    root.join("src/web/App.tsx"),
    <<~TS
      import { filterWorkOrdersByStatus, nextDispatchCandidate, seedWorkOrders, summarizeSchedule } from "../domain/work-orders";

      export function App() {
        const summary = summarizeSchedule(seedWorkOrders);
        const queued = filterWorkOrdersByStatus(seedWorkOrders, "queued");
        const candidate = nextDispatchCandidate(seedWorkOrders);

        return (
          <main>
            <h1>Field Queue</h1>
            <p>Ready work: {summary.readyCount}</p>
            <p>Queued work: {queued.length}</p>
            <p>Urgent work: {summary.urgentCount}</p>
            <p>Total estimate: {summary.totalMinutes} minutes</p>
            <section>
              <h2>Next dispatch</h2>
              <p>{candidate ? `${candidate.customer} (${candidate.id})` : "No queued work"}</p>
            </section>
          </main>
        );
      }
    TS
  )
  write(
    root.join("src/domain/work-orders.test.ts"),
    <<~TS
      import { describe, expect, it } from "vitest";
      import { filterWorkOrdersByStatus, nextDispatchCandidate, summarizeSchedule, type WorkOrder } from "./work-orders";

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

        it("filters work orders by status", () => {
          const orders: WorkOrder[] = [
            { id: "a", customer: "A", priority: "urgent", status: "queued", estimateMinutes: 10 },
            { id: "b", customer: "B", priority: "normal", status: "done", estimateMinutes: 20 }
          ];

          expect(filterWorkOrdersByStatus(orders, "queued").map((order) => order.id)).toEqual(["a"]);
        });
      });
    TS
  )
end

def implement_go(root)
  append_once(
    root.join("internal/inventory/inventory.go"),
    "func LowStockSKUs",
    <<~GO

      func LowStockSKUs(items []Item) []string {
      	candidates := ReorderCandidates(items)
      	skus := make([]string, 0, len(candidates))
      	for _, item := range candidates {
      		skus = append(skus, item.SKU)
      	}
      	return skus
      }
    GO
  )
  cli = root.join("cmd/refctl/main.go")
  cli.write(cli.read.sub(
    "case \"reorder\":\n\t\tprintJSON(inventory.ReorderCandidates(inventory.SeedItems))",
    "case \"reorder\":\n\t\tprintJSON(inventory.ReorderCandidates(inventory.SeedItems))\n\tcase \"low-stock\":\n\t\tprintJSON(inventory.LowStockSKUs(inventory.SeedItems))"
  ))
  append_once(
    root.join("internal/inventory/inventory_test.go"),
    "TestLowStockSKUs",
    <<~GO

      func TestLowStockSKUs(t *testing.T) {
      	items := []Item{
      		{SKU: "b", OnHand: 4, ReorderAt: 8},
      		{SKU: "a", OnHand: 1, ReorderAt: 2},
      	}

      	got := LowStockSKUs(items)
      	if len(got) != 2 || got[0] != "a" || got[1] != "b" {
      		t.Fatalf("unexpected low stock skus: %#v", got)
      	}
      }
    GO
  )
end

def implement_python(root)
  path = root.join("src/a2o_reference_service/appointments.py")
  path.write(path.read.sub(
    'summary = {"total": len(appointments), "booked": 0, "open": 0}',
    'summary = {"total": len(appointments), "booked": 0, "open": 0, "cancelled": 0}'
  ).sub(
    "        if appointment.status == \"open\":\n            summary[\"open\"] += 1",
    "        if appointment.status == \"open\":\n            summary[\"open\"] += 1\n        if appointment.status == \"cancelled\":\n            summary[\"cancelled\"] += 1"
  ))
  write(
    root.join("tests/test_appointments.py"),
    <<~PY
      from datetime import datetime
      import unittest

      from a2o_reference_service.appointments import Appointment, next_open_slot, summarize_appointments


      class AppointmentTests(unittest.TestCase):
          def test_summary_counts_open_and_booked_slots(self) -> None:
              appointments = [
                  Appointment("a", "A", datetime(2026, 5, 1, 9, 0), "booked"),
                  Appointment("b", "B", datetime(2026, 5, 1, 10, 0), "open"),
              ]

              self.assertEqual(
                  summarize_appointments(appointments),
                  {"total": 2, "booked": 1, "open": 1, "cancelled": 0},
              )

          def test_summary_counts_cancelled_slots(self) -> None:
              appointments = [
                  Appointment("a", "A", datetime(2026, 5, 1, 9, 0), "cancelled"),
              ]

              self.assertEqual(
                  summarize_appointments(appointments),
                  {"total": 1, "booked": 0, "open": 0, "cancelled": 1},
              )

          def test_next_open_slot_uses_earliest_open_appointment(self) -> None:
              appointments = [
                  Appointment("later", "B", datetime(2026, 5, 1, 11, 0), "open"),
                  Appointment("earlier", "A", datetime(2026, 5, 1, 10, 0), "open"),
              ]

              self.assertEqual(next_open_slot(appointments).appointment_id, "earlier")


      if __name__ == "__main__":
          unittest.main()
    PY
  )
end

def implement_java_spring(root)
  if root.join("reference-products/java-spring-multi-module/pom.xml").exist?
    root = root.join("reference-products/java-spring-multi-module")
  end

  utility = root.join("utility-lib/src/main/java/dev/a2o/reference/utility/GreetingFormatter.java")
  utility.write(<<~JAVA)
    package dev.a2o.reference.utility;

    public final class GreetingFormatter {
        private GreetingFormatter() {
        }

        public static String formatGreeting(String name) {
            return formatGreeting("Hello", name);
        }

        public static String formatGreeting(String salutation, String name) {
            String normalizedSalutation = normalizeSalutation(salutation);
            String normalizedName = normalizeName(name);
            return normalizedSalutation + ", " + normalizedName + "!";
        }

        public static String normalizeName(String name) {
            if (name == null || name.isBlank()) {
                return "A2O";
            }
            return name.trim();
        }

        private static String normalizeSalutation(String salutation) {
            if (salutation == null || salutation.isBlank()) {
                return "Hello";
            }
            return salutation.trim();
        }
    }
  JAVA

  utility_test = root.join("utility-lib/src/test/java/dev/a2o/reference/utility/GreetingFormatterTest.java")
  utility_test.write(<<~JAVA)
    package dev.a2o.reference.utility;

    import static org.assertj.core.api.Assertions.assertThat;

    import org.junit.jupiter.api.Test;

    class GreetingFormatterTest {
        @Test
        void formatsGreetingWithTrimmedName() {
            assertThat(GreetingFormatter.formatGreeting("  Kanban  ")).isEqualTo("Hello, Kanban!");
        }

        @Test
        void supportsCustomSalutation() {
            assertThat(GreetingFormatter.formatGreeting("Welcome", "Agent")).isEqualTo("Welcome, Agent!");
        }

        @Test
        void usesDefaultValuesWhenInputIsBlank() {
            assertThat(GreetingFormatter.formatGreeting(" ", "   ")).isEqualTo("Hello, A2O!");
        }
    }
  JAVA

  controller = root.join("web-app/src/main/java/dev/a2o/reference/web/GreetingController.java")
  controller.write(<<~JAVA)
    package dev.a2o.reference.web;

    import dev.a2o.reference.utility.GreetingFormatter;
    import java.util.Map;
    import org.springframework.web.bind.annotation.GetMapping;
    import org.springframework.web.bind.annotation.PathVariable;
    import org.springframework.web.bind.annotation.RequestParam;
    import org.springframework.web.bind.annotation.RestController;

    @RestController
    class GreetingController {
        @GetMapping("/greetings/{name}")
        Map<String, String> greeting(
            @PathVariable String name,
            @RequestParam(defaultValue = "Hello") String salutation
        ) {
            return Map.of("message", GreetingFormatter.formatGreeting(salutation, name));
        }

        @GetMapping("/health")
        Map<String, String> health() {
            return Map.of("status", "ok");
        }
    }
  JAVA

  controller_test = root.join("web-app/src/test/java/dev/a2o/reference/web/GreetingControllerTest.java")
  controller_test.write(<<~JAVA)
    package dev.a2o.reference.web;

    import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
    import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
    import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

    import org.junit.jupiter.api.Test;
    import org.springframework.beans.factory.annotation.Autowired;
    import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
    import org.springframework.test.web.servlet.MockMvc;

    @WebMvcTest(GreetingController.class)
    class GreetingControllerTest {
        @Autowired
        private MockMvc mockMvc;

        @Test
        void returnsGreetingFromUtilityLibrary() throws Exception {
            mockMvc.perform(get("/greetings/A2O"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.message").value("Hello, A2O!"));
        }

        @Test
        void returnsCustomSalutationGreeting() throws Exception {
            mockMvc.perform(get("/greetings/A2O").param("salutation", "Welcome"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.message").value("Welcome, A2O!"));
        }

        @Test
        void returnsHealthStatus() throws Exception {
            mockMvc.perform(get("/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("ok"));
        }
    }
  JAVA
end

def implement_catalog(root)
  path = root.join("src/catalog-service.js")
  path.write(path.read.sub(
    "available: items.filter((item) => item.available).length",
    "available: items.filter((item) => item.available).length,\n    inactive: items.filter((item) => !item.available).length"
  ))
  append_once(
    root.join("tests/catalog-service.test.js"),
    "summary.inactive",
    "\nassert.equal(summary.inactive, 1);\n"
  )
end

def implement_storefront(root)
  path = root.join("src/render-storefront.js")
  path.write(<<~JS)
    export function renderSummary(catalogSummary) {
      const inactiveText = catalogSummary.inactive === undefined ? "" : `; inactive packs: ${catalogSummary.inactive}`;
      return `Available packs: ${catalogSummary.available} of ${catalogSummary.total}${inactiveText}`;
    }

    if (process.argv[1] && process.argv[1].endsWith("render-storefront.js")) {
      console.log(renderSummary({ total: 3, available: 2, inactive: 1 }));
    }
  JS
  test_path = root.join("tests/render-storefront.test.js")
  test_path.write(<<~JS)
    import assert from "node:assert/strict";
    import { renderSummary } from "../src/render-storefront.js";

    assert.equal(renderSummary({ total: 3, available: 2 }), "Available packs: 2 of 3");
    assert.equal(renderSummary({ total: 3, available: 2, inactive: 1 }), "Available packs: 2 of 3; inactive packs: 1");
  JS
end

begin
  phase = request.fetch("phase")
  if phase == "review"
    result = success(request, summary: "deterministic parent review completed", repo_scope: "both")
  elsif phase == "implementation"
    changed = {}
    if request.fetch("slot_paths").key?("app") && editable_slot?(request, "app")
      root = slot_root(request, "app")
      if root.join("tsconfig.json").exist?
        implement_typescript(root)
        changed["app"] = ["src/domain/work-orders.ts", "src/api/server.ts", "src/web/App.tsx", "src/domain/work-orders.test.ts"]
      elsif root.join("go.mod").exist?
        implement_go(root)
        changed["app"] = ["internal/inventory/inventory.go", "cmd/refctl/main.go", "internal/inventory/inventory_test.go"]
      elsif root.join("pyproject.toml").exist?
        implement_python(root)
        changed["app"] = ["src/a2o_reference_service/appointments.py", "tests/test_appointments.py"]
      elsif (root.join("pom.xml").exist? && root.join("utility-lib/pom.xml").exist? && root.join("web-app/pom.xml").exist?) ||
            root.join("reference-products/java-spring-multi-module/pom.xml").exist?
        nested = root.join("reference-products/java-spring-multi-module/pom.xml").exist?
        prefix = nested ? "reference-products/java-spring-multi-module/" : ""
        implement_java_spring(root)
        changed["app"] = [
          "#{prefix}utility-lib/src/main/java/dev/a2o/reference/utility/GreetingFormatter.java",
          "#{prefix}utility-lib/src/test/java/dev/a2o/reference/utility/GreetingFormatterTest.java",
          "#{prefix}web-app/src/main/java/dev/a2o/reference/web/GreetingController.java",
          "#{prefix}web-app/src/test/java/dev/a2o/reference/web/GreetingControllerTest.java"
        ]
      end
    end
    if request.fetch("slot_paths").key?("repo_alpha") && editable_slot?(request, "repo_alpha")
      implement_catalog(slot_root(request, "repo_alpha"))
      changed["repo_alpha"] = ["src/catalog-service.js", "tests/catalog-service.test.js"]
    end
    if request.fetch("slot_paths").key?("repo_beta") && editable_slot?(request, "repo_beta")
      implement_storefront(slot_root(request, "repo_beta"))
      changed["repo_beta"] = ["src/render-storefront.js", "tests/render-storefront.test.js"]
    end
    raise "No supported reference product slot found" if changed.empty?

    result = success(request, summary: "deterministic implementation completed", changed_files: changed)
  else
    raise "Unsupported phase #{phase}"
  end
rescue StandardError => e
  result = fail_payload(request, e)
end

result_path.dirname.mkpath
result_path.write(JSON.pretty_generate(result))
