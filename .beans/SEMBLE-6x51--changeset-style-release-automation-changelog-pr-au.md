---
# SEMBLE-6x51
title: Changeset-style release automation (changelog PR + auto tag)
status: completed
type: feature
priority: normal
created_at: 2026-09-21T21:39:32Z
updated_at: 2026-09-21T21:44:53Z
---

Each PR carries a small change file describing its user-visible change; CI collects them on merge to main, opens a release PR that writes CHANGELOG.md and, when that PR merges, tags the version — which is what release.yml already listens for.

## Tool: knope

Chosen over the alternatives for this repo:

- **changesets** is npm-shaped; it would mean a package.json and node_modules in a Swift repo purely for release tooling, and its versioning assumes a package manifest.
- **release-please** derives versions from conventional commit messages, not from change files committed with the PR — which is what was asked for.
- **knope** is a single Rust binary with an official GitHub Action, reads changesets-format files, writes CHANGELOG.md, opens the release PR and creates the tag. It supports a package whose version lives in the git tag rather than a manifest, which is this repo's situation: the Fastfile already takes MARKETING_VERSION from the tag name.

## The gotcha that shapes the design

A tag pushed using GITHUB_TOKEN does NOT trigger other workflows. release.yml fires on push of a v* tag, so a knope-created tag would silently fail to ship a build.

Two ways out:
- Give release.yml a workflow_call trigger and have the release job invoke it directly with secrets: inherit. No new credential.
- Create the tag with a fine-grained PAT so the push event fires normally. Simpler workflow, one more secret to hold and rotate.

Taking the first; it needs no new secret and keeps release.yml's manual dispatch working.

## Tasks

- [ ] knope.toml: single package, version from git tag, changelog = CHANGELOG.md
- [ ] .changeset/ with a README explaining the format, and an initial CHANGELOG.md
- [ ] release.yml gains workflow_call
- [ ] Workflow: on push to main, knope prepare-release opens/updates the release PR
- [ ] Workflow: on that PR merging, tag and invoke the TestFlight build
- [x] CONTRIBUTING.md and docs/RELEASING.md rewritten

## Summary of Changes

Verified locally against knope 0.23.0 rather than from docs: `knope --validate` passes, and a dry run of `prepare-release` on this repo produces 0.2.1 -> 0.2.2 with the right changelog, commit, branch push and PR.

Two things the docs did not tell us, both found by running it:
- knope parses **every** .md in `.changeset/` as a change file, so a README there breaks the config. The directory holds only `.gitkeep`.
- A single package is referred to as `default` in change-file frontmatter, and its tag is plain `vX.Y.Z`, so release.yml's existing `v*` trigger still matches.

Also fixed: `project.yml` said MARKETING_VERSION 1.0.0 while the newest tag was v0.2.1. The file is now the version of record, so it was corrected to 0.2.1 — otherwise the first automated release would have jumped to 1.1.0.

Avoided a deadlock: tag-release.yml originally shared release.yml's `release` concurrency group, so the caller would have waited on the callee waiting on the caller.

Not verified: no workflow has actually run. The first real exercise is a push to main.
