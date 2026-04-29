# A2O development sample environment

This directory runs an A2O-owned sample project without touching any user's
released A2O runtime or Kanbalone board.

Ports:

- Kanbalone UI/API: `http://127.0.0.1:3471`
- A2O bundle agent port reservation: `7394`

The scripts use Docker Compose project name `a2o-dev-sample`, so volumes and
containers are separate from the default `:3470` Kanbalone instance.

## Start Kanbalone

```sh
tools/dev_sample/start-kanbalone.sh
tools/dev_sample/bootstrap-kanban.sh
```

Open `http://127.0.0.1:3471` and select the `A2ODevSampleJava` board.
`bootstrap-kanban.sh` also initializes the sample live ref
`refs/heads/a2o/dev-sample-live` from the current checkout.

## Create a sample task

```sh
tools/dev_sample/create-demo-task.sh
```

The created task is placed in `To do` with `repo:app` and
`trigger:auto-implement`.

## Run the development engine from this checkout

```sh
tools/dev_sample/start-agent.sh
tools/dev_sample/run-once.sh
```

This executes `ruby -Ilib bin/a3 execute-until-idle` from the current source
tree. It uses `.work/a2o-dev-sample/` for runtime state and talks only to the
isolated Kanbalone on port `3471` and the local agent server on port `7394`.

## Reset the isolated environment

```sh
tools/dev_sample/reset.sh
```

This removes only the `a2o-dev-sample` Docker volume, `.work/a2o-dev-sample/`,
generated `refs/heads/a2o/work/A2ODevSampleJava-*` refs, and resets the sample
live ref `refs/heads/a2o/dev-sample-live` to the current checkout.

## Stop the isolated Kanbalone

```sh
tools/dev_sample/stop-agent.sh
tools/dev_sample/stop-kanbalone.sh
```
