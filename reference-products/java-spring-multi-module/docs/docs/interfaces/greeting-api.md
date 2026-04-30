---
title: Greeting API
category: interfaces
repo_slots:
  - app
related_requirements:
  - A2O#394
related_tickets:
  - A2O#356
authorities:
  - greeting_api
---

# Greeting API

`web-app` exposes `GET /greetings/{name}`.

Baseline response:

```json
{
  "message": "Hello, A2O!"
}
```

API changes have docs-impact when they add query parameters, change response fields, or alter error behavior. Review should verify that the interface doc and the shared greeting spec stay aligned.
