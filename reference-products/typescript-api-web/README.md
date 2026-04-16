# TypeScript API and Web Reference Product

This product models a small field-service scheduling application.

It includes:

- A Node HTTP API in `src/api`.
- A React web entry in `src/web`.
- Shared TypeScript domain logic in `src/domain`.
- Vitest unit tests for the domain.
- An A2O project package in `project-package`.

## Commands

```sh
npm install
npm run typecheck
npm test
npm run build
npm run dev:api
npm run dev:web
```

## A2O Package

```sh
a2o project bootstrap --package ./project-package
```

The package contains small implementation and review skills plus scenario tasks. It is ready for a later runtime-flow validation, but this repository creation step does not start that flow.
