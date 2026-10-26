#!/usr/bin/env bash
# Builds LibRaw.xcframework (iOS, iOS simulator, macOS for host tests) into ios/CKDKit/Frameworks.
set -euo pipefail

LIBRAW_VERSION="0.22.1"
LIBRAW_COMMIT="b860248a89d9082b8e0a1e202e516f46af9adb29"
IOS_TARGET="18.0"
MACOS_TARGET="14.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_ROOT="${REPO_ROOT}/tmp/libraw-build"
SOURCE_DIR="${BUILD_ROOT}/LibRaw-${LIBRAW_VERSION}"
STAGE_DIR="${BUILD_ROOT}/stage"
OUTPUT_DIR="${REPO_ROOT}/ios/CKDKit/Frameworks"

log() { printf '[LibRaw] %s\n' "$*"; }

fetch_source() {
    if [[ ! -d "${SOURCE_DIR}/.git" ]]; then
        log "Cloning LibRaw ${LIBRAW_VERSION}"
        mkdir -p "${BUILD_ROOT}"
        git -c advice.detachedHead=false clone --quiet --depth 1 --branch "${LIBRAW_VERSION}" https://github.com/LibRaw/LibRaw.git "${SOURCE_DIR}"
    fi
    local commit
    commit="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"
    if [[ "${commit}" != "${LIBRAW_COMMIT}" ]]; then
        log "Expected commit ${LIBRAW_COMMIT}, found ${commit}"
        exit 1
    fi
}

build_slice() {
    local sdk="$1" target="$2" name="$3"
    local sdk_path clang clangxx
    sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"
    clang="$(xcrun --sdk "${sdk}" -f clang)"
    clangxx="$(xcrun --sdk "${sdk}" -f clang++)"
    log "Building ${name} (${target})"
    make -C "${SOURCE_DIR}" -f Makefile.dist clean >/dev/null 2>&1 || true
    make -C "${SOURCE_DIR}" -f Makefile.dist library -j4 \
        CC="${clang}" CXX="${clangxx}" \
        CFLAGS="-O2 -I. -w -isysroot ${sdk_path} -target ${target} -DUSE_ZLIB" \
        LDADD="-lz" >/dev/null
    mkdir -p "${STAGE_DIR}/${name}"
    cp "${SOURCE_DIR}/lib/libraw.a" "${STAGE_DIR}/${name}/libraw.a"
}

main() {
    fetch_source
    rm -rf "${STAGE_DIR}"
    build_slice iphoneos "arm64-apple-ios${IOS_TARGET}" iphoneos
    build_slice iphonesimulator "arm64-apple-ios${IOS_TARGET}-simulator" iphonesimulator
    build_slice macosx "arm64-apple-macos${MACOS_TARGET}" macosx

    mkdir -p "${STAGE_DIR}/headers"
    cp -R "${SOURCE_DIR}/libraw" "${STAGE_DIR}/headers/libraw"

    mkdir -p "${OUTPUT_DIR}"
    rm -rf "${OUTPUT_DIR}/LibRaw.xcframework"
    xcodebuild -create-xcframework \
        -library "${STAGE_DIR}/iphoneos/libraw.a" -headers "${STAGE_DIR}/headers" \
        -library "${STAGE_DIR}/iphonesimulator/libraw.a" -headers "${STAGE_DIR}/headers" \
        -library "${STAGE_DIR}/macosx/libraw.a" -headers "${STAGE_DIR}/headers" \
        -output "${OUTPUT_DIR}/LibRaw.xcframework" >/dev/null
    cp "${SOURCE_DIR}/LICENSE.CDDL" "${SOURCE_DIR}/LICENSE.LGPL" "${OUTPUT_DIR}/LibRaw.xcframework/"
    printf 'LibRaw %s\ncommit %s\niOS %s, macOS %s\n' \
        "${LIBRAW_VERSION}" "${LIBRAW_COMMIT}" "${IOS_TARGET}" "${MACOS_TARGET}" \
        > "${OUTPUT_DIR}/LibRaw.xcframework/VERSION.txt"
    log "Wrote ${OUTPUT_DIR}/LibRaw.xcframework"
}

main "$@"
