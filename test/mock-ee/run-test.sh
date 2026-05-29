#!/usr/bin/env bash
#
# End-to-end local test for the PostgreSQL edition (PG_EDITION) build flow.
#
# It spins up a mock APT repository that serves a dummy postgresql-<major><edition>
# package, builds the repository Dockerfile against it using BuildKit secret
# mounts, and asserts that the edition package was installed. The official PGDG
# repository (apt.postgresql.org) must still be reachable, since the base
# PostgreSQL tooling is pulled from there; only the edition package itself is
# mocked.
#
# Configuration (environment variables, with defaults):
#   PG_MAJOR    PostgreSQL major version              (17)
#   PG_EDITION  Edition suffix                         (ee)
#   PG_VERSION  Full PostgreSQL version for the build   (17.10)
#   PKG_VERSION Mock package version prefix             ($PG_VERSION)
#   BASE        Base image                              (ubuntu:noble)
#   REPO_PORT   Host port for the mock repository       (8080)
#   USE_INLINE_KEY  When set to "1", pass a .sources file with an inline
#                   Signed-By key instead of a separate keyring file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PG_MAJOR="${PG_MAJOR:-17}"
PG_EDITION="${PG_EDITION:-ee}"
PG_VERSION="${PG_VERSION:-17.10}"
PKG_VERSION="${PKG_VERSION:-${PG_VERSION}}"
BASE="${BASE:-ubuntu:noble}"
REPO_PORT="${REPO_PORT:-8080}"
USE_INLINE_KEY="${USE_INLINE_KEY:-0}"

PKG="postgresql-${PG_MAJOR}${PG_EDITION}"
IMAGE_TAG="postgresql-${PG_MAJOR}${PG_EDITION}-mock:local"
COMPOSE="docker compose -f ${SCRIPT_DIR}/docker-compose.yml"
SECRETS_DIR="$(mktemp -d)"

cleanup() {
  echo "==> Tearing down mock APT repository"
  PG_MAJOR="${PG_MAJOR}" PG_EDITION="${PG_EDITION}" PKG_VERSION="${PKG_VERSION}" \
    REPO_URL="http://host.docker.internal:${REPO_PORT}" \
    ${COMPOSE} down --remove-orphans >/dev/null 2>&1 || true
  rm -rf "${SECRETS_DIR}"
}
trap cleanup EXIT

echo "==> Starting mock APT repository (serving ${PKG}=${PKG_VERSION}*)"
PG_MAJOR="${PG_MAJOR}" PG_EDITION="${PG_EDITION}" PKG_VERSION="${PKG_VERSION}" \
  REPO_URL="http://host.docker.internal:${REPO_PORT}" \
  ${COMPOSE} up -d --build

echo "==> Waiting for the mock repository on http://localhost:${REPO_PORT}"
for _ in $(seq 1 30); do
  if curl -fsS "http://localhost:${REPO_PORT}/Packages" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS "http://localhost:${REPO_PORT}/Packages" >/dev/null

echo "==> Extracting APT sources and keyring from the mock repository"
CONTAINER_ID="$(docker compose -f "${SCRIPT_DIR}/docker-compose.yml" ps -q apt-repo)"
docker cp "${CONTAINER_ID}:/repo/vendor.gpg"            "${SECRETS_DIR}/vendor.gpg"
docker cp "${CONTAINER_ID}:/repo/mock-ee.sources"        "${SECRETS_DIR}/mock-ee.sources"
docker cp "${CONTAINER_ID}:/repo/mock-ee-inline.sources" "${SECRETS_DIR}/mock-ee-inline.sources"

# Build the secret flags depending on whether we use an inline key or a
# separate keyring file.
SECRET_FLAGS=()
if [ "${USE_INLINE_KEY}" = "1" ]; then
  echo "    Using inline Signed-By key (no separate keyring)"
  SECRET_FLAGS+=(--secret "id=pg_edition_sources1,src=${SECRETS_DIR}/mock-ee-inline.sources")
else
  echo "    Using external keyring + .sources reference"
  SECRET_FLAGS+=(--secret "id=pg_edition_sources1,src=${SECRETS_DIR}/mock-ee.sources")
  SECRET_FLAGS+=(--secret "id=pg_edition_keyring,src=${SECRETS_DIR}/vendor.gpg")
fi

echo "==> Building image with PG_EDITION=${PG_EDITION} against the mock repository"
DOCKER_BUILDKIT=1 docker build \
  --add-host=host.docker.internal:host-gateway \
  --target minimal \
  --build-arg "BASE=${BASE}" \
  --build-arg "PG_VERSION=${PG_VERSION}" \
  --build-arg "PG_MAJOR=${PG_MAJOR}" \
  --build-arg "PG_EDITION=${PG_EDITION}" \
  "${SECRET_FLAGS[@]}" \
  -t "${IMAGE_TAG}" \
  "${REPO_ROOT}"

echo "==> Verifying that ${PKG} was installed in the image"
MARKER="$(docker run --rm "${IMAGE_TAG}" cat "/usr/share/${PKG}/mock-marker")"
echo "    marker: ${MARKER}"

echo "PASS: end-to-end build with mock ${PKG} succeeded"
