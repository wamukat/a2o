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
6. local post-release cleanup has removed stale release leftovers that are no longer needed, including old local release Docker images that are not backing active containers
7. the A2O kanban release ticket records the final result

## Workflow

1. Prepare the release.
   - Identify the target version and release ticket.
   - Update version surfaces, image references, and docs that intentionally track the current release.

2. Verify locally.
   - Run focused release verification first.
   - Run broader verification when the blast radius warrants it.
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
   - Mark only the newest release as `latest` unless the user asks otherwise.

7. Clean up local release leftovers.
   - This cleanup is mandatory. Do not treat old local release images as harmless cache.
   - Inspect `docker ps` before deleting Docker images so you do not remove images backing active runtime or kanban containers.
   - Remove repository-local generated release artifacts that are safe to regenerate, such as temporary `.work/...` smoke outputs and `agent-go/dist`.
   - Remove exited release-validation containers, unused volumes from temporary smoke environments, dangling images, and unused builder cache.
   - Remove older local A2O release images once the new release has been confirmed, unless they are still backing active runtime or kanban containers.
   - If disk pressure is a concern, prefer aggressively removing superseded local `ghcr.io/wamukat/a2o-engine:*` tags after confirming the active runtime image in use.

8. Finish.
   - Add a final kanban comment with:
     - commit SHA(s)
     - local verification
     - workflow URL
     - image reference
     - image digest
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
