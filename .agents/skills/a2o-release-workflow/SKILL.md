---
name: a2o-release-workflow
description: "A2O release workflow. Use when releasing A2O package/runtime versions: update version surfaces, verify locally, tag and push, confirm GHCR publish, create or update the matching GitHub Release, and record the release result on the A2O kanban ticket."
---

# A2O Release Workflow

Use this skill whenever the user asks to release A2O, publish a new version, or create/update release records for A2O tags.

## Core Rule

An A2O release is not complete until all of the following are true:

1. version surfaces are updated
2. local verification has passed
3. git tag and push are complete
4. GHCR runtime image publish has succeeded
5. the matching GitHub Release exists with user-facing release notes
6. linked public issues are reviewed and either closed with release comments or explicitly left open with reasons
7. local post-release cleanup has removed stale release leftovers that are no longer needed, including old local release Docker images that are not backing active containers
8. the A2O kanban release ticket records the final result

## Workflow

1. Prepare the release.
   - Identify the target version and release ticket.
   - Update version surfaces, image references, and docs that intentionally track the current release.

2. Verify locally.
   - Run focused release verification first.
   - Run broader verification when the blast radius warrants it.
   - For behavior-changing releases or accumulated unreleased work, build a local RC runtime image and run the host-path smoke before tagging:
     - build/tag the local image as `ghcr.io/wamukat/a2o-engine:<version>-local`
     - run `VERSION=<version> agent-go/scripts/validation-local-rc-smoke.sh`
     - record the local image ID, smoke output, and any expected local-only digest limitations on the release ticket
   - The local RC smoke must exercise the installed host launcher, not only direct Ruby/runtime internals. It should catch project package validation drift, local image diagnostics, agent package export/install, and user-facing runtime commands before GHCR publish.
   - For any release that changes runtime execution, worker launcher config, scheduler selection, Kanban integration, or agent env/config generation, also run a real-task local RC smoke before tagging. This smoke must:
     - provision Kanbalone through `a2o kanban up` so lanes use the same display names A2O expects
     - create a task in the configured runnable lane with the repo label and `trigger:auto-implement`
     - run `a2o runtime watch-summary` and confirm the task is visible before execution
     - run `a2o runtime run-once` against the local RC image with the installed host launcher
     - use an executor that writes a valid worker result to `{{result_path}}`; implementation success must include `changed_files` and a non-empty `review_disposition.finding_key`
     - confirm the task reaches a terminal successful state such as `Done` / `status=done`, and confirm no removed runtime surface such as `A3_WORKSPACE_ROOT`, `A3_ROOT_DIR`, `A3_REPO_ROOT`, or `A3_BUNDLE` appears in the smoke logs
   - Do not treat `validation-local-rc-smoke.sh` alone as sufficient for execution-path changes; it uses `run-once --max-steps 0` and does not launch an actual task worker.
   - For release-reference-only changes, verify with targeted commands such as version specs, CLI specs, `git diff --check`, and stale-version searches; do not rerun the full suite after every small follow-up unless behavior changed or the previous full-suite result is stale.
   - Run the full suite once before tagging when the release candidate includes behavior changes or accumulated unreleased work warrants it. If a later review fix only touches release metadata, release bookkeeping constants that do not affect build/publish/runtime behavior, docs, or CLI help text, repeat only the focused checks that cover that fix.
   - Re-run the full suite after a follow-up fix when it touches runtime behavior, dependencies, build/package logic, a CLI execution path beyond help text, or when the previous full-suite result no longer corresponds to the candidate being tagged.
   - For release metadata or release bookkeeping constant fixes, include a lightweight confirmation that the intended constant/package descriptor changed in addition to stale-version search and focused specs.
   - Do not tag or publish until the release candidate is locally sound.

3. Commit and review.
   - Commit the release preparation work.
   - Move the release ticket to `In review`.
   - Record commit SHA(s) and verification on the ticket.
   - Run a sub-agent review loop until there are no findings.

4. Tag and push.
   - Create the annotated release tag.
   - Push `main` and the tag.

5. Confirm runtime publish.
   - Wait for the publish workflow to complete.
   - Prefer concise polling with `gh run view <run-id> --json status,conclusion,url,headSha` at reasonable intervals. Use `gh run watch` only when step-level live output is needed for diagnosis, because it can flood the transcript without making the release faster.
   - Verify the GHCR image exists.
   - Confirm at least:
     - workflow URL
     - image reference
     - image digest

6. Create or update the GitHub Release.
   - Create a GitHub Release for the matching tag if it does not exist.
   - If it already exists, update it.
   - Write user-facing release notes in English unless the user asks otherwise.
   - Summarize what changed for operators and users, not just internal ticket numbers.
   - For any release that changes runtime behavior, host launcher behavior, shared host assets, agent install/export behavior, runtime image selection, or generated runtime/agent configuration, include an explicit `Migration / Upgrade Steps` section. The section must say whether users need to update the host launcher, shared assets, runtime image/container, project agent binary, project package config, or generated state, and must include concrete commands where possible.
   - If the release removes a compatibility surface, include an explicit migration note that names the removed command/config/env, explains the replacement, and says the runtime now fails fast with a migration-required diagnostic instead of silently preserving the compatibility layer.
   - Do not include local Kanbalone/A2O ticket URLs in release notes. Link only to public GitHub issues or pull requests when referencing tickets.
   - Mark only the newest release as `latest` unless the user asks otherwise.

7. Close completed public issues.
   - Review every public GitHub issue or pull request linked from the release notes.
   - Close an issue only when the released scope satisfies the issue. If the release intentionally ships an MVP or partial scope, confirm that the remaining scope is explicitly future work or is tracked separately before closing.
   - Add a closing comment that links the GitHub Release and states the released behavior.
   - Do not close issues merely because they were mentioned in release notes.

8. Clean up local release leftovers.
   - This cleanup is mandatory. Do not treat old local release images as harmless cache.
   - Inspect `docker ps` before deleting Docker images so you do not remove images backing active runtime or kanban containers.
   - Remove repository-local generated release artifacts that are safe to regenerate, such as temporary `.work/...` smoke outputs and `agent-go/dist`.
   - Remove exited release-validation containers, unused volumes from temporary smoke environments, dangling images, and unused builder cache.
   - Remove older local A2O release images once the new release has been confirmed, unless they are still backing active runtime or kanban containers.
   - If disk pressure is a concern, prefer aggressively removing superseded local `ghcr.io/wamukat/a2o-engine:*` tags after confirming the active runtime image in use.

9. Finish.
   - Add a final kanban comment with:
     - commit SHA(s)
     - local verification
     - workflow URL
     - image reference
     - image digest
     - completed public issues closed, or the reason each linked issue remains open
     - cleanup summary
     - GitHub Release URL
     - review result
   - Move the release ticket to `Done`.

## Notes

- If GitHub Releases are missing for earlier recent tags and the user asks, create them retroactively with concise user-facing notes.
- Treat GitHub Release creation as part of the package release, not optional follow-up work.
- Do not stop at tag push while publish confirmation or GitHub Release creation is still pending.
- Do not run destructive cleanup blindly. Preserve any active runtime / kanban containers and any evidence or artifacts that still need investigation.
- Local retention of superseded A2O release images is not the default. After each confirmed release, clean them up unless there is an explicit reason to preserve them.
