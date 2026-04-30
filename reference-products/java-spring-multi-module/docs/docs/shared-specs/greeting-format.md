---
title: Greeting format
category: shared_specs
repo_slots:
  - lib
related_requirements:
  - A2O#394
related_tickets:
  - A2O#356
authorities:
  - greeting_shared_spec
---

# Greeting Format

`utility-lib` owns greeting normalization and message formatting. The baseline English message is:

```text
Hello, <name>!
```

When a task introduces another language or salutation rule, update this shared spec with the rule before or together with implementation. `web-app` should consume the library behavior instead of duplicating formatting logic.
