# Python Service Reference Product

This product models a small appointment service that can run in a host or dev-env agent environment.

It intentionally uses the Python standard library for the service and tests so the first runtime-flow validation does not depend on package installation.

## Commands

```sh
PYTHONPATH=src python3 -m unittest discover -s tests
PYTHONPATH=src python3 -m compileall src tests
PYTHONPATH=src python3 -m a2o_reference_service.app
```

## A2O Package

```sh
a2o project bootstrap --package ./project-package
```
