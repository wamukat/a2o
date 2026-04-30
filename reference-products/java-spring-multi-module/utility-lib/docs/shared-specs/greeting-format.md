---
title: Greeting Format
category: shared_specs
status: active
related_requirements:
  - A2O#394
related_tickets:
  - A2ODevSampleJava#1
authorities:
  - greeting_shared_spec
audience:
  - maintainer
  - ai_worker
owners:
  - utility-lib
---

The utility library owns greeting message formatting rules. Web-facing modules
must call this library instead of duplicating locale-specific message logic.
