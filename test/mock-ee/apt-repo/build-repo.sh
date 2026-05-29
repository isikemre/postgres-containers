#!/bin/sh
#
# Generates a dummy PostgreSQL edition package (e.g. postgresql-17ee) and a
# minimal flat APT repository hosting it. This is used to test the PG_EDITION
# build flow end to end, fully locally, without access to a real enterprise
# APT repository.
#
# In addition to the repository itself, this script generates:
# - A GPG signing key pair and keyring (vendor.gpg)
# - A signed APT repository with Release / InRelease files
# - A deb822 .sources file ready for /etc/apt/sources.list.d/
#
# Configuration is provided through environment variables:
#   PG_MAJOR    PostgreSQL major version (default: 17)
#   PG_EDITION  Edition suffix appended to the package name (default: ee)
#   PKG_VERSION Package version prefix, must match the build's PG_VERSION
#               (default: 17.10)
#   REPO_DIR    Output directory for the repository (default: ./repo)
#   REPO_URL    URL at which the repository will be reachable (default:
#               http://host.docker.internal:8080). Embedded in the generated
#               .sources file.
set -eu

PG_MAJOR="${PG_MAJOR:-17}"
PG_EDITION="${PG_EDITION:-ee}"
PKG_VERSION="${PKG_VERSION:-17.10}"
REPO_DIR="${REPO_DIR:-./repo}"
REPO_URL="${REPO_URL:-http://host.docker.internal:8080}"

PKG="postgresql-${PG_MAJOR}${PG_EDITION}"
VERSION="${PKG_VERSION}-1.mock"
BUILD_DIR="$(mktemp -d)"

echo "==> Building dummy package ${PKG}=${VERSION}"

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

# ---------- GPG keyring + signed Release ----------
echo "==> Generating mock GPG signing key"
export GNUPGHOME="$(mktemp -d)"
cat > "${GNUPGHOME}/keygen" <<EOF2
%no-protection
Key-Type: RSA
Key-Length: 2048
Subkey-Type: RSA
Subkey-Length: 2048
Name-Real: Mock EE Vendor
Name-Email: mock@example.com
Expire-Date: 0
%commit
EOF2
gpg --batch --gen-key "${GNUPGHOME}/keygen" 2>/dev/null

# Export the public key (binary .gpg) for Signed-By references
gpg --batch --export > "${REPO_DIR}/vendor.gpg"

# Also export an ASCII-armored copy to embed in .sources files with inline keys
gpg --batch --export --armor > "${REPO_DIR}/vendor.asc"

# Generate Release file and sign it
apt-ftparchive release "${REPO_DIR}" > "${REPO_DIR}/Release"
gpg --batch --yes --armor --detach-sign -o "${REPO_DIR}/Release.gpg" "${REPO_DIR}/Release"
gpg --batch --yes --clearsign -o "${REPO_DIR}/InRelease" "${REPO_DIR}/Release"

rm -rf "${GNUPGHOME}"

# ---------- Generate deb822 .sources file ----------
# This file references the keyring at the conventional path where the
# Dockerfile will place it (/usr/share/keyrings/pg-edition.gpg).
cat > "${REPO_DIR}/mock-ee.sources" <<EOF3
Types: deb
URIs: ${REPO_URL}
Suites: ./
Signed-By: /usr/share/keyrings/pg-edition.gpg
EOF3

# Also generate a .sources variant with the key embedded inline, for users
# who prefer not to pass a separate keyring file.
{
  echo "Types: deb"
  echo "URIs: ${REPO_URL}"
  echo "Suites: ./"
  echo "Signed-By:"
  sed 's/^/ /' "${REPO_DIR}/vendor.asc"
} > "${REPO_DIR}/mock-ee-inline.sources"

echo "==> Mock APT repository ready in ${REPO_DIR}:"
ls -l "${REPO_DIR}"
