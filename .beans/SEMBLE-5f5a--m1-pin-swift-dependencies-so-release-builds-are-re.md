---
# SEMBLE-5f5a
title: 'M1: Pin Swift dependencies so release builds are reproducible'
status: completed
type: task
priority: normal
created_at: 2026-09-21T13:06:01Z
updated_at: 2026-09-21T13:34:49Z
parent: SEMBLE-m5pi
---

Package.resolved is gitignored and Jot floats at from: 0.1.1 (anything < 1.0.0), so the signed build takes whatever Jot tag exists at build time, and the provenance attestation covers unpinned inputs.

- [ ] Stop ignoring Package.resolved and commit the resolved file
- [ ] CI and the fastlane beta lane build with -disableAutomaticPackageResolution
- [x] Remove -skipPackagePluginValidation from ci.yml

## Note: why not -disableAutomaticPackageResolution

XcodeGen does not generate .xcodeproj/project.xcworkspace/xcshareddata/swiftpm/, so xcodebuild has no resolved file to honour and that flag just fails the build. Copying Packages/SembleKit/Package.resolved into place would be plumbing whose originHash behaviour could not be verified here (Xcode is not installed on this machine, only Command Line Tools).

Instead Jot is now `exact: "0.1.1"` alongside OAuthenticator's existing revision pin. Neither dependency has transitive dependencies, so the graph is fully determined by Package.swift whichever resolved file a generated project reads. That is the property M1 wanted, with no CI plumbing to rot.

Unverified: no xcodebuild invocation could be run locally. CI is the first real test of the -skipPackagePluginValidation removal.

## Summary of Changes

- `.gitignore`: stopped ignoring `Package.resolved`; the resolved file is now tracked.
- `Packages/SembleKit/Package.swift`: Jot pinned `exact: "0.1.1"` (was `from:`), alongside OAuthenticator's existing revision pin.
- `.github/workflows/ci.yml`: `swift test` gains `--only-use-versions-from-resolved-file`; `-skipPackagePluginValidation` removed from the xcodebuild step.
- `fastlane/Fastfile`: same flag on the `test` lane.

Verified: `swift build --package-path Packages/SembleKit --only-use-versions-from-resolved-file` succeeds and resolution yields the same two revisions as before.

NOT verified: nothing involving xcodebuild or XCTest can run on this machine (Command Line Tools only, no Xcode — `swift test` fails with 'unable to resolve module dependency: XCTest'). CI is the first place the ci.yml change is exercised.
