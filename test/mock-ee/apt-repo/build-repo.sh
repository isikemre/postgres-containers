#!/bin/sh
#
# Generates a dummy PostgreSQL edition package (e.g. postgresql-17ee) and a
# minimal flat APT repository hosting it. This is used to test the PG_EDITION
# build flow end to end, fully locally, without access to a real enterprise
# APT repository.
#
# Configuration is provided through environment variables:
#   PG_MAJOR    PostgreSQL major version (default: 17)
#   PG_EDITION  Edition suffix appended to the package name (default: ee)
#   PKG_VERSION Package version prefix, must match the build's PG_VERSION
#               (default: 17.10)
#   REPO_DIR    Output directory for the repository (default: /repo)
set -eu

PG_MAJOR="${PG_MAJOR:-17}"
PG_EDITION="${PG_EDITION:-ee}"
PKG_VERSION="${PKG_VERSION:-17.10}"
REPO_DIR="${REPO_DIR:-/repo}"

PKG="postgresql-${PG_MAJOR}${PG_EDITION}"
VERSION="${PKG_VERSION}-1.mock"
BUILD_DIR="$(mktemp -d)"

echo "Building dummy package ${PKG}=${VERSION}"

mkdir -p "${BUILD_DIR}/DEBIAN"
cat > "${BUILD_DIR}/DEBIAN/control" <<EOF
Package: ${PKG}
Version: ${VERSION}
Section: database
Priority: optional
Architecture: all
Maintainer: Mock EE <mock@example.com>
Description: Dummy ${PKG} package for local end-to-end build testing
 This is a mock package used to validate the PostgreSQL edition (PG_EDITION)
 build flow without access to a real enterprise APT repository. It installs a
 marker file only and ships no PostgreSQL binaries.
EOF

# Install a marker file so the resulting image can be inspected/asserted upon.
# Avoid /usr/share/doc since minimal Ubuntu/Debian images exclude it via dpkg.
mkdir -p "${BUILD_DIR}/usr/share/${PKG}"
echo "mock ${PKG} ${VERSION}" > "${BUILD_DIR}/usr/share/${PKG}/mock-marker"

mkdir -p "${REPO_DIR}"
dpkg-deb --build "${BUILD_DIR}" "${REPO_DIR}/${PKG}_${VERSION}_all.deb"
rm -rf "${BUILD_DIR}"

# Generate flat repository metadata (Packages / Packages.gz at the repo root).
cd "${REPO_DIR}"
dpkg-scanpackages . /dev/null > Packages
gzip -kf Packages

echo "Mock APT repository ready in ${REPO_DIR}:"
ls -l "${REPO_DIR}"
