# Contributing to MeetingCard

Thanks for helping. This is a small personal tool, so the process is light.

## Before you start

- For anything bigger than a bug fix, open an issue first so we can agree on the shape before you write code.
- Issues labelled `good first issue` are scoped to be doable without knowing the whole codebase.

## Setup

You need macOS 15+ on Apple Silicon, Xcode, and xcodegen (`brew install xcodegen`). You do **not** need gws or a Google account to build or run the tests: the test suite uses fake gws runners and JSON fixtures, and fixture mode (`swift/scripts/show-fixture.sh`) renders cards without touching a calendar.

```sh
cd swift
./scripts/build.sh test      # generate the project and run the tests
./scripts/build.sh build     # tests + Release build, ad-hoc signed if you have no signing identity
```

## Making a change

- Keep logic in `swift/Core/` (Foundation only, unit-tested) and keep `swift/App/` a thin AppKit shell. If you add a behavior, add a test in `swift/Tests/` that fails without your change.
- Put any new test data in `swift/Tests/Fixtures/`. **Never commit real calendar data**: no real meeting titles, attendee names or emails, company domains, or real meeting IDs. Use `example.com`, made-up titles, and obviously fake IDs.
- The app must never log event content (titles, descriptions, attendees). Log ids, counts and reasons. (It currently logs meeting links; redacting them is an open issue.)
- Never call gws with a stripped environment. Always go through `Gws.buildEnv()`.
- UI changes: attach light and dark screenshots to the PR (`show-fixture.sh <fixture> <light|dark> 3 --snapshot out.png`).
- One logical change per PR, with a short description of what changed and how you tested it.

## Pull requests

CI runs `./scripts/build.sh build` (tests + Release build) on a macOS runner. A PR needs a green run and a maintainer review before merge.

By contributing, you agree that your contributions are licensed under the project's [MIT License](LICENSE), and you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
