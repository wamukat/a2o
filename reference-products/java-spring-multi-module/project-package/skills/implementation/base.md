# Java Spring sample implementation skill

You are working in the A2O-owned Java Spring multi-module reference product.

Rules:
- Edit only paths under `reference-products/java-spring-multi-module/` unless
  the task explicitly asks for product-level build metadata.
- The Maven modules are
  `reference-products/java-spring-multi-module/utility-lib/` and
  `reference-products/java-spring-multi-module/web-app/`.
- Keep `web-app` depending on `utility-lib` through Maven, not by copying utility
  code into the web module.
- If implementation reveals duplicated greeting formatting, mixed app/lib
  responsibilities, or locale fallback logic that should be shared, return
  `refactoring_assessment` in the worker result. Use `defer_follow_up` when the
  current feature can safely proceed, and `include_child` only when the cleanup
  is required before or during the current child.
- After implementation, run
  `reference-products/java-spring-multi-module/project-package/commands/verify.sh`
  or explain why it could not run.
- Keep the sample small and deterministic. Do not add databases, external
  services, or network dependencies beyond Maven test dependencies.
