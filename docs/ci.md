# Continuous Integration

The project uses GitHub Actions for CI. Workflows are defined in `.github/workflows/`.

## PR Checks

When a PR is opened, the following checks run automatically:

- **SwiftLint** (`swiftlint.yml`) — checks Swift code style
- **Build and Run Offline Tests** (`swift.yml`) — builds the FFI from source (with caching), builds the Swift package, and runs the `OfflineTests` suite. It also runs on every push to `main`, which keeps warm the caches every pull request restores

## FFI Build Workflow

The **Build FFI XCFramework** workflow (`build-ffi.yml`) is triggered manually
via `workflow_dispatch`. It runs `./Scripts/ci/build-release-artifacts.sh`, which
builds the full XCFramework for every platform, verifies that the Swift package
builds and passes `OfflineTests` when linked against it, then zips it with its
checksum and uploads it as a draft GitHub Release.

That verification runs before the upload, not after: a mismatch across the FFI
boundary compiles on both sides and fails only at link or run time, so it is
the last point at which one can be caught before the artifact is public.

It touches no git or pull-request state, which is why it needs only
`contents: write`. The SDK release skill can dispatch this workflow, wait for
it, and write the resulting URL and checksum into `Package.swift`.

## Manual Deployment

Prerequisites:
- Write permissions on the repo
- `gh` CLI installed and authenticated
- Rust toolchain with all Apple platform targets
- A tag signing key configured

Releases are prepared with the SDK release skill from the shared ZODL skills
library; see "Cutting a release" in `CONTRIBUTING.md`. The release XCFramework
is built and uploaded as a draft by `Scripts/ci/build-release-artifacts.sh`.
`Scripts/prepare-release.sh` is a deprecated stub.

A version with a pre-release suffix, such as `2.8.0-rc.1`, is marked as a
pre-release on GitHub at every point it is created, re-uploaded or published.
