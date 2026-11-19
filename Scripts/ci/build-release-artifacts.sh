#!/usr/bin/env bash
#
# build-release-artifacts.sh: build the XCFramework for all five Apple
# architectures, zip it, and upload it to GitHub as a DRAFT release.
#
# Called by the SDK release skill from the shared ZODL skills library and by
# the Build FFI XCFramework workflow (.github/workflows/build-ffi.yml). It
# touches no git or pull-request state.
#
# Run it for its options: ./Scripts/ci/build-release-artifacts.sh --help
#
# Sourcing this file defines the functions below and does nothing else, so
# Scripts/tests/run-tests.sh can exercise them without a network or a build.
#
# Compatible with bash 3.2, which remains available on macOS.

# Paths, relative to the repository root.
PRODUCTS_DIR="BuildSupport/products"
ZIP_FILE="libzcashlc.xcframework.zip"
DEFAULT_REPO="zodl-inc/zodl-swift-wallet-sdk"

# Set by argument parsing.
DRY_RUN="${DRY_RUN:-false}"

step() { echo; echo "==> $*"; }

die() {
    echo "error: $1" >&2
    shift
    while [ $# -gt 0 ]; do echo "       $1" >&2; shift; done
    exit 1
}

run() {
    if [ "$DRY_RUN" = "true" ]; then
        echo "  would run: $*"
    else
        "$@"
    fi
}

# Requested release names must be representable by the native artifact flow.
require_supported_release_version() {
    case "$1" in
        *+*) die "unsupported build metadata in requested SDK release version '$1'." ;;
    esac
}

# SemVer: the hyphen introduces the pre-release identifiers, so 2.8.0-rc.1 is a
# pre-release and 2.8.0 is not.
is_prerelease() {
    case "$1" in
        *-*) return 0 ;;
        *)   return 1 ;;
    esac
}

# The `gh release` argument that makes a release's pre-release bit agree with
# its version. GitHub keeps that bit separately from the tag, and it is what
# stops a release candidate from being served as `latest` to everyone who asks
# the API for the newest release.
#
# Stated in both directions rather than only when set, because `gh release
# upload` replaces assets but not release properties: a draft created before
# the version gained or shed its suffix would otherwise keep the stale bit.
prerelease_flag() {
    if is_prerelease "$1"; then
        printf '%s\n' "--prerelease=true"
    else
        printf '%s\n' "--prerelease=false"
    fi
}

# The version declared in a manifest's [package] table. `version` also appears
# in the dependency tables, so the search is scoped to [package] and stops at
# the next table heading.
cargo_package_version() {
    awk '
        /^\[/ { in_pkg = ($0 == "[package]") }
        in_pkg && /^version[[:space:]]*=/ {
            sub(/^version[[:space:]]*=[[:space:]]*"/, "")
            sub(/"[[:space:]]*$/, "")
            print
            exit
        }
    ' "$1"
}

# $1 names how to report a failure, defaulting to `die`. Callers whose
# --dry-run path makes no authenticated call pass `die_unless_dry_run`, so a
# rehearsal reports the problem instead of refusing to run. Callers whose dry
# run does reach GitHub keep the default: without a token those reads fail
# anyway, and further along, with a message that misdiagnoses the cause.
require_gh_auth() {
    local report="${1:-die}"
    if ! command -v gh >/dev/null 2>&1; then
        "$report" "the GitHub CLI (gh) is not installed." \
            "See https://cli.github.com/"
        return
    fi
    if ! gh auth status >/dev/null 2>&1; then
        "$report" "gh is not authenticated." "Run: gh auth login"
    fi
}

# Zip the XCFramework. -y stores symlinks as links: without it zip follows them
# and the macOS slice's versioned-framework links become three copies of the
# library, which no longer unpack as a framework.
create_release_archive() {
    ( cd "$PRODUCTS_DIR" && rm -f "$ZIP_FILE" && zip -qry "$ZIP_FILE" libzcashlc.xcframework )
}

# Build the Swift package and run the offline tests against the XCFramework
# that was just built, by pointing Package.swift at it through LocalPackages.
#
# This is the first time anything links the new framework. A mismatch across
# the FFI boundary -- a changed signature, a dropped symbol -- compiles on both
# sides and surfaces only at link or run time, so without this the first
# consumer to find out is a user who has already upgraded.
verify_against_local_ffi() {
    local had_local_packages=false

    if [ -d LocalPackages ]; then
        had_local_packages=true
        echo "  LocalPackages/ already exists and will be replaced"
    fi

    step "Verifying the SDK against the freshly built XCFramework"
    run make configure-local-ffi
    check_native_record configure-local-ffi
    run make build
    check_native_record build
    run make test-offline
    check_native_record test-offline

    # Leave the tree as we found it. LocalPackages/ is gitignored, but its mere
    # presence switches Package.swift from the released binary target to the
    # local one, so leaving it behind would silently change what the operator's
    # next build links against.
    if [ "$had_local_packages" = "false" ]; then
        run rm -rf LocalPackages
    else
        echo "  leaving LocalPackages/ in place; it predates this run"
        echo "  re-run ./Scripts/init-local-ffi.sh if you need it rebuilt"
    fi
}

# Proof is opt-in for native CLI callers and always enabled by the release workflow.
check_native_record() {
    if [ "${ZODL_SDK_BUILD_RECORD:-}" = "1" ]; then
        if [ $# -gt 0 ]; then
            python3 Scripts/ci/sdk_build_record.py check "$SDK_RECORD_CONTEXT" --command "$1"
        else
            python3 Scripts/ci/sdk_build_record.py check "$SDK_RECORD_CONTEXT"
        fi
    fi
}

# Build, archive and upload. Returns with $PRODUCTS_DIR/release.env written.
# Callers set GH_REPO; it falls back to the repository the workflow runs in
# (GITHUB_REPOSITORY under Actions) and then to the canonical repository, so a
# CI dispatch needs no argument and a fork publishes its own releases instead of
# failing with 403 against upstream.
produce_artifacts() {
    local version="$1" force="$2" verify="$3"
    local manifest_version checksum download_url exists

    require_supported_release_version "$version"

    : "${GH_REPO:=${GITHUB_REPOSITORY:-$DEFAULT_REPO}}"
    export GH_REPO

    if [ "${ZODL_SDK_BUILD_RECORD:-}" = "1" ]; then
        [ "$verify" = "true" ] && [ "$DRY_RUN" = "false" ] || \
            die "native build evidence requires verification and a real build."
        rm -f "${PRODUCTS_DIR}/release.env" "${PRODUCTS_DIR}/sdk-build-record.json"
        SDK_RECORD_CONTEXT="$(mktemp)"
        trap 'rm -f "${SDK_RECORD_CONTEXT:-}"' EXIT
        python3 Scripts/ci/sdk_build_record.py begin "$SDK_RECORD_CONTEXT" --version "$version"
    fi

    require_gh_auth

    manifest_version="$(cargo_package_version Cargo.toml)"
    if [ "$manifest_version" != "$version" ]; then
        die "Cargo.toml declares version ${manifest_version}, not ${version}." \
            "Bump it during release preparation (the SDK release skill), or dispatch this build" \
            "from a branch where the bump has already landed."
    fi

    if is_prerelease "$version"; then
        echo "  ${version} carries a pre-release suffix; the release will be marked as a pre-release"
    fi

    # Check before the ten-minute build, not after: nothing below depends on
    # the build or the checksum, so a doomed run should fail in a second, the
    # same reasoning that puts the version guard above ahead of the build.
    exists=false
    if gh release view "$version" --repo "$GH_REPO" >/dev/null 2>&1; then
        if [ "$force" != "true" ]; then
            die "release ${version} already exists." \
                "Use --force-overwrite-existing-release to replace its assets."
        fi
        # Only a draft may be overwritten. Package.swift pins the checksum of
        # whatever asset a published release carries, and SwiftPM checks it at
        # fetch time, so replacing the bytes behind that URL breaks the build of
        # everyone who has already resolved ${version} -- and keeps breaking it,
        # because a published tag is immutable. The remedy is a new version.
        if [ "$(gh release view "$version" --repo "$GH_REPO" \
                --json isDraft --jq .isDraft)" != "true" ]; then
            die "release ${version} is published; its assets will not be replaced." \
                "Package.swift pins the checksum of the asset attached to it, and" \
                "SwiftPM verifies that checksum on every fetch. Replacing the asset" \
                "would break the build of every consumer that has resolved ${version}." \
                "Release a new version instead."
        fi
        echo "  draft release ${version} exists; replacing its assets"
        exists=true
    fi

    step "Building the XCFramework for ${version} (this takes a while)"
    run make clean-ffi
    check_native_record clean-ffi
    run make ffi-all
    check_native_record ffi-all

    # Between the build and the upload, deliberately: this is the last point at
    # which a broken FFI boundary can be caught before the artifact is public.
    if [ "$verify" = "true" ]; then
        verify_against_local_ffi
    else
        echo "  skipping the build-and-test verification (--skip-verify)"
    fi

    step "Creating the release archive"
    if [ "$DRY_RUN" = "true" ]; then
        echo "  would zip ${PRODUCTS_DIR}/${ZIP_FILE} and checksum it"
        echo "  would upload it to ${GH_REPO} as a draft release"
        return 0
    fi

    create_release_archive
    checksum="$(shasum -a 256 "${PRODUCTS_DIR}/${ZIP_FILE}" | awk '{print $1}')"
    download_url="https://github.com/${GH_REPO}/releases/download/${version}/${ZIP_FILE}"
    echo "  ${ZIP_FILE}: ${checksum}"

    if [ "${ZODL_SDK_BUILD_RECORD:-}" = "1" ]; then
        python3 Scripts/ci/sdk_build_record.py finish "$SDK_RECORD_CONTEXT" \
            --archive "${PRODUCTS_DIR}/${ZIP_FILE}" \
            --destination "${PRODUCTS_DIR}/sdk-build-record.json"
    fi

    step "Uploading to ${GH_REPO} as a draft release"
    check_native_record
    if [ "$exists" = "true" ]; then
        gh release upload "$version" "${PRODUCTS_DIR}/${ZIP_FILE}" \
            --repo "$GH_REPO" --clobber
        # `gh release upload` replaces assets, never release properties, so the
        # pre-release bit has to be set on its own. A draft cut before this
        # handling existed carries whatever it was created with.
        check_native_record
        gh release edit "$version" --repo "$GH_REPO" "$(prerelease_flag "$version")"
    else
        gh release create "$version" "${PRODUCTS_DIR}/${ZIP_FILE}" \
            --repo "$GH_REPO" --title "$version" \
            --notes "Zcash Light Client SDK ${version}" --draft \
            "$(prerelease_flag "$version")"
    fi

    if [ "${ZODL_SDK_BUILD_RECORD:-}" = "1" ]; then
        check_native_record
        if [ "$exists" = "true" ]; then
            gh release upload "$version" "${PRODUCTS_DIR}/sdk-build-record.json" --repo "$GH_REPO" --clobber
        else
            gh release upload "$version" "${PRODUCTS_DIR}/sdk-build-record.json" --repo "$GH_REPO"
        fi
        check_native_record
    fi

    # Only write this once the upload has actually succeeded: everything it
    # records was already known beforehand, so this is a pure reordering, but
    # a caller trusting this file must never see a DOWNLOAD_URL that 404s.
    cat > "${PRODUCTS_DIR}/release.env" <<EOF
CHECKSUM=${checksum}
DOWNLOAD_URL=${download_url}
VERSION=${version}
EOF

    echo "  draft release: https://github.com/${GH_REPO}/releases/tag/${version}"
}

usage() {
    cat <<'EOF'
Usage: ./Scripts/ci/build-release-artifacts.sh [options] <version>

Build the XCFramework for all five Apple architectures, zip it, and upload it
to GitHub as a DRAFT release. Writes BuildSupport/products/release.env with the
checksum and download URL. A version carrying a pre-release suffix, such as
2.8.0-rc.1, is marked as a pre-release on GitHub.

This touches no git state and no pull request, which is what lets
.github/workflows/build-ffi.yml run it with only `contents: write`.

It refuses unless Cargo.toml already declares <version>. A dispatched CI build
takes its version from the workflow input but its sources from the branch; were
the two allowed to disagree, the upload would carry the right name and the
wrong library.

Before uploading, it points Package.swift at the framework it just built via
LocalPackages, builds the Swift package, and runs the OfflineTests suite. A
mismatch across the FFI boundary compiles on both sides and fails only at link
or run time, so this is the last point at which one can be caught cheaply.

Build metadata (+suffix) is unsupported in requested release versions, including
dry runs and resumed builds. Stable and prerelease versions are supported.

Options:
  --force-overwrite-existing-release  replace the assets of an existing DRAFT
                                      release. A published release is refused:
                                      Package.swift pins its asset's checksum,
                                      so replacing it breaks every consumer
                                      that has already resolved the version.
  --skip-verify                       do not build and test the SDK against the
                                      new XCFramework before uploading it
  --dry-run                           print what would happen and change nothing
EOF
}

main() {
    local force=false verify=true version

    local -a positional=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --force-overwrite-existing-release) force=true; shift ;;
            --skip-verify) verify=false; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            -h|--help) usage; return 0 ;;
            --*)       usage >&2; die "unknown option '$1'" ;;
            *)         positional+=("$1"); shift ;;
        esac
    done
    # Options may appear anywhere, including after the positionals.
    set -- ${positional[@]+"${positional[@]}"}

    if [ $# -lt 1 ]; then
        usage >&2
        die "a version is required."
    fi
    version="${1#v}"
    require_supported_release_version "$version"

    produce_artifacts "$version" "$force" "$verify"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail

    cd "$(git rev-parse --show-toplevel)"

    # Find the normal toolchain without sourcing interactive or personal startup.
    if ! command -v cargo >/dev/null 2>&1; then
        export PATH="$HOME/.cargo/bin:$PATH"
    fi

    main "$@"
fi
