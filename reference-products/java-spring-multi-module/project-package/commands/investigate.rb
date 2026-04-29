#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

request = JSON.parse(File.read(ENV.fetch("A2O_DECOMPOSITION_REQUEST_PATH")))
slot_paths = request.fetch("slot_paths", {})

app_slot = slot_paths.fetch("app", nil)
sample_root =
  if app_slot && File.exist?(File.join(app_slot, "pom.xml"))
    app_slot
  elsif app_slot
    File.join(app_slot, "reference-products", "java-spring-multi-module")
  end

modules = []
if sample_root && Dir.exist?(sample_root)
  modules = Dir.children(sample_root)
    .select { |entry| File.directory?(File.join(sample_root, entry)) && File.exist?(File.join(sample_root, entry, "pom.xml")) }
    .sort
end

result = {
  "summary" => "Investigated #{request.fetch('task_ref')} against the Java Spring multi-module sample.",
  "product" => {
    "type" => "maven spring boot multi-module web api",
    "modules" => modules,
    "current_endpoints" => [
      "GET /health",
      "GET /greetings/{name}"
    ]
  },
  "source_request" => {
    "title" => request.fetch("title"),
    "description" => request.fetch("description")
  },
  "breakdown_guidance" => [
    "Keep utility formatting behavior in utility-lib when possible.",
    "Keep HTTP routing and response contracts in web-app.",
    "Add or update controller tests for externally visible behavior."
  ]
}

File.write(ENV.fetch("A2O_DECOMPOSITION_RESULT_PATH"), "#{JSON.pretty_generate(result)}\n")
