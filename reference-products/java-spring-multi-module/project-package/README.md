# A2O Java Spring sample project package

This package points A2O at the local Java Spring multi-module reference product.
It is for A2O engine development only and uses the isolated Kanbalone project
`A2ODevSampleJava`.

The package declares three repo slots:

- `app`: Spring Boot `web-app`
- `lib`: Java `utility-lib`
- `docs`: dedicated docs surface under `../docs`

The `docs` config is intentionally small but complete enough to exercise
docs-impact decisions, shared specs, interface docs, authority sources, managed
index blocks, and mirror policy.

Command inventory:

- `commands/verify.sh`: runtime verification command.
- `commands/format.sh`: runtime remediation command.
- `commands/investigate.rb`, `commands/author-proposal.rb`,
  `commands/review-proposal.rb`: decomposition pipeline commands.
- `commands/bootstrap.sh`: local readiness check for the sample workspace.
- `commands/build.sh`: local Maven packaging helper used during manual sample
  development.

Use `tools/dev_sample/README.md` from the repository root to start the isolated
Kanbalone instance and run the development engine.
