#!/usr/bin/env bash
#
# prepare-release.sh: deprecated. It no longer prepares releases, whatever
# arguments it is given.

cat >&2 <<'MSG'
Scripts/prepare-release.sh is deprecated and no longer prepares releases.

SDK releases are prepared with the zodl iOS release scripts and skills from
the shared ZODL skills library.

The release XCFramework is built, verified and uploaded by
Scripts/ci/build-release-artifacts.sh, which the SDK release skill and the
Build FFI XCFramework workflow run.
MSG
exit 1
