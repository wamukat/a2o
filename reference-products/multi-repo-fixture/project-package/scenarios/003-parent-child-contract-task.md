# Scenario: Parent-child contract task

Create one parent task with labels:

- `a2o:ready`
- `repo:both`
- `kind:parent`

Parent task body:

Coordinate a cross-repo catalog contract change. The catalog-service child should expose an `inactive` field in the summary. The storefront child should render that field in the summary output. Verify both repositories before parent completion.

Expected child labels:

- Catalog child: `repo:catalog`, `kind:child`
- Storefront child: `repo:storefront`, `kind:child`
