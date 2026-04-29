#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

request = JSON.parse(File.read(ENV.fetch("A2O_DECOMPOSITION_REQUEST_PATH")))
roles_path = ARGV.fetch(0, nil)
if roles_path && !File.absolute_path?(roles_path)
  command_relative = File.expand_path(roles_path, __dir__)
  package_relative = File.expand_path(roles_path, File.expand_path("..", __dir__))
  roles_path = File.exist?(command_relative) ? command_relative : package_relative
end
module_roles = roles_path && File.exist?(roles_path) ? JSON.parse(File.read(roles_path)) : {}
role_modules = module_roles.fetch("modules", {})
slot_paths = request.fetch("slot_paths", {})

app_slot = slot_paths.fetch("app", nil)
lib_slot = slot_paths.fetch("lib", nil)
sample_root =
  if app_slot && File.exist?(File.join(File.dirname(app_slot), "pom.xml")) && File.basename(app_slot) == "web-app"
    File.dirname(app_slot)
  elsif lib_slot && File.exist?(File.join(File.dirname(lib_slot), "pom.xml")) && File.basename(lib_slot) == "utility-lib"
    File.dirname(lib_slot)
  elsif app_slot && File.exist?(File.join(app_slot, "pom.xml")) && File.exist?(File.join(app_slot, "utility-lib/pom.xml"))
    app_slot
  elsif lib_slot && File.exist?(File.join(lib_slot, "pom.xml")) && File.exist?(File.join(lib_slot, "utility-lib/pom.xml"))
    lib_slot
  elsif app_slot
    File.join(app_slot, "reference-products", "java-spring-multi-module")
  end

modules = []
if sample_root && Dir.exist?(sample_root)
  modules = Dir.children(sample_root)
    .select { |entry| File.directory?(File.join(sample_root, entry)) && File.exist?(File.join(sample_root, entry, "pom.xml")) }
    .sort
elsif !role_modules.empty?
  modules = slot_paths.filter_map do |slot, path|
    role = role_modules[slot]
    next unless role && File.exist?(File.join(path, "pom.xml"))

    role.fetch("path", slot)
  end.sort
end

result = {
  "summary" => "Investigated #{request.fetch('task_ref')} against the Java Spring multi-module sample.",
  "product" => {
    "type" => "maven spring boot multi-module web api",
    "modules" => modules,
    "module_roles" => module_roles.fetch("modules", {}),
    "routing_hints" => module_roles.fetch("routing_hints", []),
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
