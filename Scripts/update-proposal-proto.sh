#!/usr/bin/env bash
#
# update-proposal-proto.sh: vendor the FFI proposal.proto from librustzcash.
#
# The canonical definition lives in zcash/librustzcash at
# zcash_client_backend/proto/proposal.proto. libzcashlc encodes proposals with
# whatever schema the pinned zcash_client_backend was built against, so the
# copy compiled into this SDK has to match that exact version: any field the
# copy lacks is a field Swift cannot read.
#
# Unlike the lightwallet protos there is no git subtree to derive from, because
# the upstream version is chosen by a Cargo dependency rather than by a tag this
# repository pulls. The pinned version is therefore read out of Cargo.lock and
# the matching upstream file is fetched over HTTPS.
#
# The derivation adds one thing upstream does not carry: `option swift_prefix`.
# Without it the generated types would collide with the SDK's own names, so
# taking upstream verbatim is not an option.
#
# This script updates the .proto ONLY. The generated proposal.pb.swift is
# committed, so after running this you must regenerate it with protoc and the
# protoc-gen-swift version pinned in Package.resolved; see
# Scripts/update-lightwallet-protocol.sh, which builds that plugin and is the
# reference for how generated sources are produced in this repository.
#
# Usage:
#   ./Scripts/update-proposal-proto.sh           # rewrite the vendored copy
#   ./Scripts/update-proposal-proto.sh --check   # fail if it has drifted (CI)
#
# Both modes are idempotent and neither needs a clean working tree. --check
# writes nothing; it is what the Proto Sync workflow runs.

set -euo pipefail

readonly UPSTREAM_REPO="zcash/librustzcash"
readonly UPSTREAM_PATH="zcash_client_backend/proto/proposal.proto"
readonly CRATE="zcash_client_backend"
readonly LOCK="Cargo.lock"
readonly DEST="Sources/ZODLSwiftWalletSDK/Modules/Service/GRPC/ProtoBuf/proto/proposal.proto"
readonly SWIFT_PREFIX="Ffi"

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
cd "${REPO_ROOT}"

usage() {
    sed -n '2,31p' "$0" | sed 's|^# \{0,1\}||'
    exit "${1:-1}"
}

# Prints version, source, and archive checksum from the exact lock entry.
read_lock_entry() {
    awk -v want="${CRATE}" '
        function emit() {
            if (name == want) { print version "\t" source "\t" checksum; found = 1 }
        }
        /^\[\[package\]\]$/ {
            emit()
            if (found) exit
            name = ""; version = ""; source = ""; checksum = ""; next
        }
        /^name = / { gsub(/^name = "|"$/, ""); name = $0; next }
        /^version = / { gsub(/^version = "|"$/, ""); version = $0; next }
        /^source = / { gsub(/^source = "|"$/, ""); source = $0; next }
        /^checksum = / { gsub(/^checksum = "|"$/, ""); checksum = $0; next }
        END { if (!found) emit() }
    ' "${LOCK}"
}

# Registry tags need not exist. The checksum-verified published archive records
# the source commit and crate directory in .cargo_vcs_info.json. Read only that
# member rather than extracting an untrusted archive onto the filesystem.
upstream_location() {
    local entry version source checksum archive
    entry="$(read_lock_entry)"
    if [ -z "${entry}" ]; then
        echo "error: no ${CRATE} entry in ${LOCK}." >&2
        return 1
    fi
    IFS=$'\t' read -r version source checksum <<< "${entry}"

    case "${source}" in
        registry+https://github.com/rust-lang/crates.io-index)
            if [[ ! "${version}" =~ ^[0-9A-Za-z.+-]+$ ]] ||
               [[ ! "${checksum}" =~ ^[0-9a-f]{64}$ ]]; then
                echo "error: invalid registry version or checksum for ${CRATE}." >&2
                return 1
            fi
            archive="${WORK_DIR}/crate.tar.gz"
            if ! curl -fsSL "https://static.crates.io/crates/${CRATE}/${CRATE}-${version}.crate" -o "${archive}"; then
                echo "error: could not fetch ${CRATE} ${version} archive." >&2
                return 1
            fi
            python3 - "${archive}" "${checksum}" "${CRATE}-${version}" <<'PYTHON'
import hashlib
import json
import re
import sys
import tarfile

archive, checksum, crate = sys.argv[1:]
try:
    with open(archive, "rb") as source:
        if hashlib.sha256(source.read()).hexdigest() != checksum:
            raise ValueError("crate checksum mismatch")
    with tarfile.open(archive, "r:gz") as source:
        name = crate + "/.cargo_vcs_info.json"
        members = [member for member in source.getmembers() if member.name == name]
        if len(members) != 1 or not members[0].isfile() or members[0].size > 65536:
            raise ValueError("missing or invalid crate provenance")
        with source.extractfile(members[0]) as metadata_file:
            metadata = json.load(metadata_file)
    revision = metadata["git"]["sha1"]
    path = metadata["path_in_vcs"]
    if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", revision):
        raise ValueError("invalid source revision")
    if (not isinstance(path, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*", path)
            or any(part in (".", "..") for part in path.split("/"))):
        raise ValueError("invalid crate source path")
    print(revision + "\t" + path + "/proto/proposal.proto")
except (OSError, ValueError, KeyError, TypeError, tarfile.TarError) as error:
    sys.exit("error: invalid crate provenance: " + str(error))
PYTHON
            ;;
        git+*)
            local revision="${source##*#}"
            if [[ "${source}" != *'#'* ]] || [[ ! "${revision}" =~ ^[0-9a-fA-F]{40}$ ]]; then
                echo "error: git source for ${CRATE} pins no valid revision." >&2
                return 1
            fi
            printf '%s\t%s\n' "${revision}" "${UPSTREAM_PATH}"
            ;;
        *)
            echo "error: unrecognized source for ${CRATE}: '${source}'." >&2
            return 1
            ;;
    esac
}

# Writes the derived proto for the given upstream ref to stdout.
derive() {
    local ref="$1"
    local path="$2"
    local url="https://raw.githubusercontent.com/${UPSTREAM_REPO}/${ref}/${path}"
    local upstream
    upstream="${WORK_DIR}/upstream.proto"

    if ! curl -fsSL "${url}" -o "${upstream}"; then
        echo "error: could not fetch ${url}" >&2
        echo "       Is ${ref} pushed to ${UPSTREAM_REPO}?" >&2
        exit 1
    fi

    if grep -q '^option swift_prefix' "${upstream}"; then
        echo "error: upstream now sets swift_prefix itself." >&2
        echo "       This script's injection is obsolete; vendor it verbatim." >&2
        exit 1
    fi

    if ! grep -q '^package ' "${upstream}"; then
        echo "error: upstream has no 'package' declaration to anchor the injection." >&2
        exit 1
    fi

    cat <<EOF
// DERIVED FILE -- DO NOT EDIT.
//
// Generated by Scripts/update-proposal-proto.sh from
// ${UPSTREAM_REPO}/${UPSTREAM_PATH}
// at the ${CRATE} version pinned in ${LOCK}.
//
// The only change from upstream is the added \`option swift_prefix\` below.
// Bump the dependency and re-run the script rather than editing this file,
// then regenerate proposal.pb.swift.

EOF
    awk -v prefix="${SWIFT_PREFIX}" '
        { print }
        !injected && /^package / {
            print "option swift_prefix = \"" prefix "\";"
            injected = 1
        }
    ' "${upstream}"
}

main() {
    local mode="${1:-update}"
    local location ref path
    WORK_DIR="$(mktemp -d)"
    readonly WORK_DIR
    trap 'rm -rf "${WORK_DIR}"' EXIT
    location="$(upstream_location)"
    IFS=$'\t' read -r ref path <<< "${location}"
    # Stage beside the destination so the final rename is atomic even when the
    # system temporary directory is on a different filesystem.
    if [ "${mode}" = update ]; then
        DERIVED_FILE="$(mktemp "${DEST}.XXXXXX")"
    else
        DERIVED_FILE="${WORK_DIR}/derived.proto"
    fi
    trap 'rm -rf "${WORK_DIR}"; rm -f "${DERIVED_FILE}"' EXIT
    if [ "${mode}" = update ] && [ -e "${DEST}" ]; then
        cp -p "${DEST}" "${DERIVED_FILE}"
    fi
    derive "${ref}" "${path}" > "${DERIVED_FILE}"

    case "${mode}" in
        update)
            mv "${DERIVED_FILE}" "${DEST}"
            echo "Derived ${DEST} from ${UPSTREAM_REPO}@${ref}."
            echo
            echo "proposal.pb.swift is committed and is NOT regenerated by this"
            echo "script. Regenerate it with the protoc-gen-swift version pinned"
            echo "in Package.resolved before committing; see"
            echo "Scripts/update-lightwallet-protocol.sh for how this repository"
            echo "builds that plugin."
            ;;
        check)
            if diff -u "${DEST}" "${DERIVED_FILE}"; then
                echo "${DEST} matches ${UPSTREAM_REPO}@${ref}."
            else
                echo >&2
                echo "error: ${DEST} has drifted from ${UPSTREAM_REPO}@${ref}," >&2
                echo "       the ${CRATE} version pinned in ${LOCK}." >&2
                echo "       Run ./Scripts/update-proposal-proto.sh, regenerate" >&2
                echo "       proposal.pb.swift, and commit both." >&2
                exit 1
            fi
            ;;
    esac
}

case "${1:-}" in
    -h|--help)
        usage 0
        ;;
    --check)
        main check
        ;;
    '')
        main update
        ;;
    *)
        echo "error: unknown option '$1'." >&2
        usage 1
        ;;
esac
