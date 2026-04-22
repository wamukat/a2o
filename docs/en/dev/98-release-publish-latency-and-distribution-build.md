# Release Publish Latency And Distribution Build

This note records why A2O release publish is slow and how to improve it without breaking the current install surface.

## Current Observation

Recent runtime-image publish runs show that the single `Build runtime image` step is the dominant bottleneck.

- Run `24773195829`: `Build runtime image` took about `14m38s`
- Run `24778382881`: `Build runtime image` took about `18m11s`

Local Docker build observations show the same shape.

- `agent-builder` took about `215s`
- base runtime dependency install and bundler setup took roughly `80s + 11s`

The publish latency is therefore structural, not an incidental CI slowdown.

## Why It Is Slow

The runtime image Dockerfile currently embeds agent package assembly.

1. The publish workflow builds a multi-arch runtime image:
   - `linux/amd64`
   - `linux/arm64`
2. Inside the Dockerfile, the `agent-builder` stage runs `agent-go/scripts/build-release.sh`
3. That script currently builds four host targets:
   - `darwin/amd64`
   - `darwin/arm64`
   - `linux/amd64`
   - `linux/arm64`
4. The runtime image then copies the generated agent package directory into `/opt/a2o/agents`

So one runtime-image publish currently includes:

- Linux runtime image build for two container platforms
- full host agent distribution build for four host targets
- Ruby dependency installation
- Debian package installation

These are separate responsibilities, but today they are coupled in one publish path.

## Why The Extra Targets Exist

The extra host targets are not accidental.

Current user-facing install flows rely on the runtime image as the source of packaged host artifacts:

- `a2o host install`
- `a2o agent install`
- `a3 agent package list|verify|export`

The runtime image contains `/opt/a2o/agents/release-manifest.jsonl` plus per-target archives, and the install/export commands read from that package store.

That means simply dropping `darwin` packages from the image would break current macOS host install flows.

## Boundary Problem

The main design issue is not the base image itself. The main issue is boundary mixing:

- runtime image publish
- host/agent distribution build
- install-package source of truth

are handled as one unit.

This makes the current user experience simple, but it makes release publish slow.

## Implemented Contract Baseline

`A2O#157` defines the compatibility baseline that later distribution separation must preserve.

The package-set contract is now:

- `release-manifest.jsonl` remains the archive inventory for `a3 agent package list|verify|export`
- `package-compatibility.json` is the package-set compatibility contract
- the consuming runtime version and the package-set `runtime_version` must match exactly
- `a3 host install` validates the contract when a package directory exposes either the compatibility file or the archive manifest

Legacy package directories without either file still work for host-launcher-only fixtures, but published package sets are expected to carry the compatibility contract.

## Implemented Install Resolution Baseline

`A2O#158` defines the install-time resolution and fallback baseline for later distribution separation.

The current policy is:

- `a2o agent install --package-source auto` prefers `--package-dir` or `A2O_AGENT_PACKAGE_DIR` / `A3_AGENT_PACKAGE_DIR`
- if auto mode discovers a package directory only through the environment and validation fails, install falls back to the runtime image
- `--package-dir` in auto mode is treated as an explicit operator choice and does not fall back
- `--package-source package-dir` requires a compatible host package directory and never falls back
- `--package-source runtime-image` skips host package discovery and uses the embedded runtime-image package store

## Improvement Options

### Option A: Small optimization only

Keep the current packaging model and optimize Dockerfile/cache behavior.

Possible work:

- reduce apt/bundler churn
- improve layer reuse
- reduce unnecessary context invalidation

Expected improvement:

- limited
- likely incremental only

Risk:

- low

### Option B: Separate distribution assembly from runtime image publish

Keep the current CLI surface, but move host agent package assembly out of the runtime-image Docker build.

Possible shape:

- build/publish host agent packages in a separate workflow or job
- publish a manifest and archives as release assets or another package surface
- keep `a2o agent install` and `a2o host install` unchanged from the user point of view
- change the implementation so install/export resolves packages from the new distribution source

Expected improvement:

- substantial
- this is the main structural lever

Risk:

- medium
- requires package-source and install-path redesign

Before this option can move into implementation, the design has to be split into concrete decisions:

1. Package publication surface
   - where host agent manifests and archives are published
   - how versioned artifacts are addressed
   - how checksums and integrity verification are carried
2. Install-time resolution and fallback policy
   - how `a2o agent install` and `a2o host install` find the right package
   - what happens offline or when the preferred package source is unavailable
   - whether the runtime image remains a fallback source during migration
3. Runtime-image compatibility boundary
   - which host artifacts stay embedded during migration
   - when it is safe to reduce embedded targets
   - how compatibility with current macOS install flows is preserved

### Option C: After separation, slim runtime image contents

Once the install flow no longer depends on the runtime image for every host target, reduce what the runtime image embeds.

Possible work:

- keep only runtime-needed Linux artifacts in the image
- or stop embedding host package archives entirely

Expected improvement:

- high, but only after Option B

Risk:

- high if attempted before install-path separation

## Recommended Sequence

1. Decide the package publication surface
2. Decide install-time resolution and fallback policy
3. Decide the runtime-image compatibility boundary during migration
4. Implement distribution separation while preserving the CLI surface
5. Switch install/export implementation to the new distribution source
6. Reduce runtime-image embedded host package contents
7. Apply smaller Dockerfile/cache cleanup on top

## Expected Improvement Range

Based on current timings:

- small Dockerfile-only cleanup: modest improvement
- structural distribution separation: likely the main gain
- full boundary cleanup after separation: large improvement potential

A realistic target is to reduce publish from the current mid-to-high teens of minutes into a clearly smaller range, but that requires the structural change rather than only image-layer tuning.

## Follow-up Breakdown

The follow-up tickets map to the work as follows:

- `A2O#159`: define the host agent package publication surface
- `A2O#158`: define install-time package resolution and fallback policy
- `A2O#157`: define the runtime-image and external-package compatibility contract
- `A2O#155`: implement distribution separation after `A2O#157`, `A2O#158`, and `A2O#159`
- `A2O#156`: second-order Dockerfile/cache optimization after the structural boundary is improved
