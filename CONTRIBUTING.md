# Contributing

Thanks for taking a look. Issues and pull requests are welcome; small,
focused changes are easiest to review.

## Before you start

- Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). It explains the layers
  and, importantly, what the app deliberately does *not* do (no backend of
  its own, and no dependencies beyond the two OAuth/JWT libraries).
- For anything beyond a bug fix, open an issue first so we can agree on the
  shape of the change before you spend time on it.

## Style

- Readable and conventional Swift. Prefer the obvious SwiftUI or Foundation
  way of doing something over a clever one; the share extension has a tight
  memory budget and a reviewer has to be able to audit everything.
- No new third-party dependencies without discussion. OAuth and DPoP come
  from [OAuthenticator](https://github.com/ATProtoKit/OAuthenticator) and
  [Jot](https://github.com/ATProtoKit/Jot) precisely so that we don't
  maintain security-sensitive code ourselves; everything else is in-tree.
- Tests define intent. Write them as statements of behaviour ("a rejected
  PAR with `use_dpop_nonce` is retried once with the nonce"), not as
  assertions about byte layouts. A change in behaviour should come with the
  test that describes it.
- Error messages shown to the user must make sense to a person.
- British English in docs and UI copy.
- Keep the website's prose short and plain. `web/` is checked against
  Simplified Technical English with
  [stuffbucket/vale](https://github.com/stuffbucket/vale): short sentences,
  the active voice, no contractions. Its vocabulary rules come from an
  aerospace wordset, so ignore the suggestions that rename product terms
  ("note" to "record", "save" to "keep"); take the errors and warnings.

## Running the tests

All unit tests live in the `SembleKit` package and run on macOS without Xcode
project generation:

```sh
make test
# or: swift test --package-path Packages/SembleKit --parallel
```

To build the app itself, see "Building locally" in the [README](README.md).
CI runs both on every push.

## Commits and pull requests

- One logical change per pull request.
- Explain *why* in the description; the diff already shows *what*.
- CI must be green.
- If the change is one a user of the app would notice, describe it in a change
  file (below).

## Change files

A pull request that changes what someone using the app would notice adds a
file to `.changeset/`. Write one with `knope document-change`, or by hand as
`.changeset/anything.md`:

```markdown
---
default: minor
---

Links carrying a query string now wait for you to ask before a preview is
fetched.
```

`default` is this repo's one package. The level is `major`, `minor` or
`patch`; while the version is below 1.0 these shift down one, so a `minor`
change bumps the patch number. Write the text as a changelog entry — for
someone deciding whether to update, not for a reviewer reading the diff.

A pull request that changes nothing a user would notice (CI, tests, internal
refactoring) needs no file.

Merging to `main` opens a release pull request collecting these entries; see
[docs/RELEASING.md](docs/RELEASING.md).
