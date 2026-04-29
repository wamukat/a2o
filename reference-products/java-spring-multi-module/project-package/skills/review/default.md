# Java Spring sample review skill

Review changes for the A2O-owned Java Spring multi-module reference product.

Flag findings when:
- `web-app` no longer depends on `utility-lib` through Maven.
- Java code bypasses existing utility behavior instead of extending it.
- Tests no longer cover both modules.
- The verification command cannot run from a materialized A2O workspace.
- The change adds non-deterministic external runtime dependencies.

Treat a clean review as eligible for verification.

