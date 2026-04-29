# Add salutation support to greetings

Labels:
- `repo:app`
- `trigger:auto-implement`

## Request

Extend the greeting API so callers can request a salutation-specific greeting.
The `web-app` endpoint should continue to use `utility-lib` for message
formatting instead of duplicating formatting logic in the controller.

## Acceptance

- `utility-lib` exposes the formatting behavior.
- `web-app` has an endpoint that returns the new greeting shape.
- Maven tests pass for the whole reactor.

