# Java Spring multi-module reference product

This reference product is owned by the A2O repository and is intended for local
runtime development. It is a Maven reactor with two modules:

- `utility-lib`: a plain Java library with small formatting utilities.
- `web-app`: a Spring Boot web application that depends on `utility-lib`.
- `docs`: a dedicated docs repo slot used by the project package to validate
  docs-impact behavior for app docs, shared specs, interface docs, authorities,
  and ja/en mirror policy.

The product package lives in `project-package/`. Use the scripts under
`tools/dev_sample/` to run it against an isolated local Kanbalone instance.

## Local checks

```sh
mvn test
mvn -pl web-app spring-boot:run
curl http://127.0.0.1:8080/greetings/A2O
```

The project package verification script also supports A2O split-slot runtime
workspaces. When `A2O_WORKER_REQUEST_PATH` provides separate `app` and `lib`
slot paths, `project-package/commands/verify.sh` installs the reactor parent POM
from this reference product before testing the separated modules.
