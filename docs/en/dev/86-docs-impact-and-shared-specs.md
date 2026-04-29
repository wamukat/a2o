# Docs Impact and Shared Specification Documents

This document defines how A2O treats documentation updates as part of development work.

A2O should not add a mandatory design phase. Instead, implementation, review, and parent review should decide `docs-impact` and accumulate architecture, shared specifications, external interface notes, rationale, and traceability in the project's documentation system.

## 1. Problem

A2O can decompose, implement, and review tickets. If design decisions and shared specifications only remain in code and ticket comments, several problems follow.

- Humans cannot easily understand feature structure and rationale.
- AI workers can miss existing shared capabilities and implement similar-but-different duplicates.
- Shared specifications such as DB definitions, external API ACLs, project-package schema, and runtime event models become scattered.
- External interface specifications and user-facing behavior drift from implementation.
- It is hard to trace which requirement or remote issue introduced a feature.

The need is not a heavy design approval phase. The need is systematic documentation updates as development work products.

## 2. Goals

- Let project-package define docs root, docs repo, categories, index, and authorities.
- Let A2O decide docs-impact per ticket.
- Let implementation, review, and parent review add or update required docs.
- Use shared specification documents as pre-implementation context for AI workers.
- Preserve traceability between requirements, parent tickets, remote issues, implementation tickets, and related docs.
- Maintain a human-readable table of contents.
- Respect source-of-truth artifacts when external interface specs, DB schemas, or generated docs have an authority outside Markdown.

## 3. Non-Goals

A2O is not a documentation platform.

- It does not generate documentation sites.
- It does not provide document approval workflows.
- It does not manage publication, permissions, reader-specific portals, or search UI.
- It does not replace OpenAPI, Javadoc, TypeDoc, DB migrations, or GraphQL schema tools.
- It does not require documentation updates on every ticket.

A2O's responsibility ends at docs-impact classification, related-doc discovery, required Markdown/spec updates, index updates, evidence, and review checks.

A2O does not implicitly own:

- docs publication
- complete navigation site generation
- document approval status
- translation completeness
- team docs ownership

Projects that need those concerns should use project docs policy and external tools.

## 4. Project-Package Docs Configuration

The project-package declares where docs live and how they are organized.

```yaml
docs:
  root: docs
  index: docs/README.md
  policy: docs/policy.md
  categories:
    architecture: docs/architecture
    shared_specs: docs/shared-specs
    frameworks: docs/frameworks
    data_model: docs/data-model
    acl: docs/integrations/acl
    interfaces: docs/interfaces
    features: docs/features
    decisions: docs/decisions
    operations: docs/operations
    migration: docs/migration
```

When docs live in a separate repo slot:

```yaml
docs:
  repoSlot: docs
  root: docs
  index: docs/README.md
```

Without `repoSlot`, docs are assumed to live in the primary repo slot. A2O resolves docs paths inside the target repo slot checkout, not relative to the project-package root.

A2O may update a docs repo only when that repo is declared as a repo slot. It must not clone or push to an undeclared external docs repository.

## 4.1 Validation Rules

Docs config is validated strictly, like prompt / skill config.

- `root`, `index`, category paths, and authority paths are relative paths inside the target repo slot.
- Absolute paths, `..` escapes, and symlink escapes are rejected.
- `repoSlot` must match a declared repo slot.
- Category IDs must be non-empty, unique, stable machine-readable keys.
- Missing docs roots are created or rejected according to project policy.
- If front matter has a schema version, unrecognized versions are warning or error according to policy.
- Authority sources must exist, or project policy must declare them as generated artifacts.

Validation should be available through doctor-style diagnostics, not only during docs writes.

## 5. Documentation Categories

Initial first-class categories:

| category | Purpose |
| --- | --- |
| `architecture` | System structure, boundaries, components, and data flow. |
| `shared_specs` | Shared specifications that prevent duplicate local implementations. |
| `frameworks` | Product-specific frameworks, shared libraries, and extension points. |
| `data_model` | DB, persistence, domain model, and migration policy. |
| `acl` | External API calls, adapters, anti-corruption layers, auth, and retry policy. |
| `interfaces` | External interfaces, APIs, CLI, events, and config schemas. |
| `features` | User-visible feature behavior. |
| `decisions` | Rationale, rejected alternatives, and tradeoffs. |
| `operations` | Operations, incident handling, settings, release, and monitoring. |
| `migration` | Compatibility, migration steps, and breaking-change handling. |

Projects may add categories. A2O core should still treat the categories above as first-class vocabulary for docs-impact decisions and review prompts.

## 6. Shared Specifications

`shared_specs` are constraints that help AI workers avoid duplicating similar mechanisms.

Examples:

- runtime event model
- Kanban ticket state model
- project-package config schema
- prompt composition model
- workspace / branch / repo slot model
- DB schema / domain model
- external API ACL policy
- error handling / retry / validation policy
- logging / evidence / trace model

A2O should discover relevant shared specifications before implementation and include them as worker request context. Workers should be told not to create new local mechanisms that conflict with existing shared specs.

When a task introduces a new shared capability or boundary, it should add or update `shared_specs` or the relevant category on the same branch as the implementation.

## 7. Authorities and Derived Docs

Markdown is not always the source of truth.

The project-package can declare authorities:

```yaml
docs:
  authorities:
    db_schema:
      source: db/migrate
      docs: docs/data-model
    http_api:
      source: openapi.yaml
      docs: docs/interfaces/http-api.md
    graphql_api:
      source: schema.graphql
      docs: docs/interfaces/graphql-api.md
    cli:
      source: lib/cli
      docs: docs/interfaces/cli.md
    shared_runtime:
      docs: docs/shared-specs/runtime.md
```

When an authority exists, A2O prioritizes the source-of-truth artifact. Markdown is used for explanation, rationale, operations, and reader-oriented structure. For example, if OpenAPI is the HTTP API authority, updating only Markdown cannot complete an API change.

Authority precedence must be deterministic.

```text
declared authority source
  > project-package docs
  > generated evidence / artifacts
  > ticket text / comments
```

Unless a project-package declares an exception for a specific authority, A2O uses this order. If docs conflict with the authority, A2O must not pass the change by editing Markdown only; review should produce a finding or rework.

## 8. Front Matter and Traceability

A2O-managed docs should use front matter when practical.

```markdown
---
title: Prompt Composition Model
category: shared_specs
audience:
  - maintainer
  - ai_worker
status: active
related_requirements:
  - A2O#371
related_tickets:
  - A2O#372
  - A2O#374
authorities:
  - project_package_schema
---
```

Candidate required fields:

- `title`
- `category`
- `status`
- `related_requirements`
- `related_tickets`

Candidate optional fields:

- `audience`
- `source_issues`
- `authorities`
- `owners`
- `updated_by`
- `supersedes`

A2O uses this metadata to navigate from requirements to docs, from docs to implementation tickets, and from implementation tickets to rationale.

Front matter is not the source of truth for lifecycle state. Kanban current state, review disposition, run status, and merge status remain owned by evidence, ticket comments, and runtime state. Docs front matter should contain long-lived requirement refs, source issues, related tickets, authorities, and document status only.

## 8.1 Multi-Language Docs

The project-package can declare language policy.

```yaml
docs:
  languages:
    canonical: ja
    mirrored:
      - en
    policy: require_canonical_warn_mirror
```

Initial policies:

- `require_all`: every declared language must be updated in the same branch.
- `require_canonical_warn_mirror`: canonical docs are required; mirror docs are warning / follow-up.
- `canonical_only`: A2O updates only canonical docs.

A2O's own docs are mirrored in `ja` and `en`, so the A2O project-package should at least record mirror debt in evidence.

## 9. Docs-Impact Decision

The implementation worker decides docs-impact during ticket work.

Typical docs-impact:

- A new runtime concept is added.
- Project-package config, schema, prompt, or skill surface changes.
- Kanban state transitions, labels, or scheduler rules change.
- Multi-project, multi-repo, branch, workspace, or repo-slot boundaries change.
- DB schema, external API, CLI, config schema, or event schema changes.
- Shared libraries, product frameworks, or ACLs change.
- An existing design direction changes.
- A future AI worker would likely need the rationale.

Typical no docs-impact:

- A small bug fix within an existing documented behavior.
- A local implementation change that does not affect common boundaries or user behavior.
- A simple implementation that follows existing docs.

When uncertain, the worker records `maybe` in evidence and leaves the decision to review.

Docs-impact severity is configurable.

```yaml
docs:
  impactPolicy:
    shared_specs: block_review
    interfaces: block_review
    data_model: block_review
    decisions: warn
    features: warn
```

`block_review` requires a review finding / rework when docs are missing. `warn` records evidence and comments and may be converted into a parent-review follow-up ticket.

## 10. Runtime Flow

### 10.1 Pre-Implementation Context

Worker request composition discovers candidate docs from the ticket body, repo slot, phase, related requirement, and project docs policy.

Signals include:

- category match
- front matter `related_requirements`
- source issue / parent ticket / child ticket relation
- repo slot / authority
- project-package docs policy

Candidate docs are passed as reference context. A2O should pass path / title / summary / relevant excerpt first, not every full document.

The worker request includes at least:

- docs config summary
- candidate docs path / title / category / reason
- relevant authority sources
- expected docs actions
- docs-impact policy and severity
- traceability refs
- language policy

`docs_context` is optional and absent for projects without `docs` config. When present, it is carried on implementation, review, and parent-review worker requests. Decomposition commands may also receive the same shape when they need to draft child tickets that respect existing shared specs.

The worker result may include a structured `docs_impact` object. A2O validates the object without making docs mandatory for every task:

- `disposition`: `yes`, `no`, or `maybe`
- `categories`: docs categories that were considered
- `updated_docs`: docs paths changed by the worker
- `updated_authorities`: authoritative sources changed or confirmed
- `skipped_docs`: `{ path, reason }` entries for intentional omissions
- `matched_rules`: evidence rules that drove the decision
- `review_disposition`: review outcome for the docs decision
- `traceability`: related requirements, tickets, and source issues

### 10.2 Implementation Updates

When docs-impact exists, the implementation worker updates docs on the implementation branch.

Targets include:

- category Markdown
- source-of-truth spec
- index / TOC
- front matter
- migration / operations notes

### 10.3 Review

The review worker checks:

- Whether docs-impact was classified correctly.
- Whether the implementation created a duplicate mechanism instead of using shared specs.
- Whether changed external interfaces, DB, CLI, config, or events are reflected in authorities and docs.
- Whether front matter and traceability are present.
- Whether index / TOC updates are present when needed.

### 10.4 Parent Review

Parent review checks documentation across child tickets.

- Multiple children must not write separate docs for the same shared spec.
- Parent requirement, feature docs, shared specs, and implementation tickets should be traceable.
- Feature docs and shared specs should not be mixed.
- Follow-up docs tickets should be created when needed.

## 10.5 Shared Specs Handling

Shared specs are both read-only inputs and update targets.

- If an existing shared spec applies, the worker reads it as a constraint.
- If the implementation requires changing a shared spec, the same branch updates the shared spec.
- Implementations that conflict with a shared spec must not pass without an explicit design decision update.

Review checks whether the implementation created a duplicate mechanism when it should have used an existing shared spec.

## 11. Index / TOC

A2O performs minimal index updates.

- If `docs.index` is configured, new docs are added to the categorized index.
- If a category has a README / index, that category index is updated.
- A2O-managed blocks can protect human-authored content.

Example:

```markdown
<!-- a2o-docs-index:start category=shared_specs -->
- [Prompt Composition Model](shared-specs/prompt-composition.md)
- [Runtime Event Model](shared-specs/runtime-events.md)
<!-- a2o-docs-index:end -->
```

Without a managed block, index updates should be conservative. If ambiguous, A2O records a docs-impact review finding.

## 12. Evidence

Run evidence records the docs-impact decision.

```json
{
  "docs_impact": {
    "disposition": "yes",
    "categories": ["shared_specs", "interfaces"],
    "updated_docs": [
      "docs/shared-specs/prompt-composition.md",
      "docs/interfaces/project-package-schema.md"
    ],
    "updated_authorities": [
      "project.yaml schema"
    ],
    "skipped_docs": [
      {
        "path": "docs/en/interfaces/project-package-schema.md",
        "reason": "mirror policy allows follow-up"
      }
    ],
    "matched_rules": [
      "project_package_schema_changed"
    ],
    "review_disposition": "accepted",
    "traceability": {
      "related_requirements": ["A2O#371"],
      "related_tickets": ["A2O#372", "A2O#374"]
    }
  }
}
```

Kanban comments should only include a concise summary.

## 13. Relationship to Prompt / Skill Configuration

This design complements A2O#371.

- Implementation prompts can require docs-impact decisions.
- Review prompts can require documentation consistency checks.
- Repo slot addons can add backend / frontend / library-specific docs policy.
- Decomposition prompts can include traceability guidance in child drafts.

Docs-impact should not rely on prompts alone. A2O runtime should treat docs-impact as first-class evidence and review checklist data.

## 14. Ticket Breakdown

Implementation should be split into:

- project-package docs config schema and loader
- docs front matter / index / authority model
- docs-impact decision and related-doc injection into worker requests
- implementation / review / parent_review docs-impact evidence and checklist
- docs update helpers and index management
- shared spec / authority / traceability sample project-package and E2E
- migration and user docs
