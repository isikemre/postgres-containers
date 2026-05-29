#!/usr/bin/env bash
#
# End-to-end local test for the PostgreSQL edition (PG_EDITION) build flow.
#
# It spins up a mock APT repository that serves a dummy postgresql-<major><edition>
# package, builds the repository Dockerfile against it, and asserts that the
# edition package was installed. The official PGDG repository (apt.postgresql.org)
# must still be reachable, since the base PostgreSQL tooling is pulled from there;
# only the edition package itself is mocked.
#
# Configuration (environment variables, with defaults):
#   PG_MAJOR    PostgreSQL major version            (17)
#   PG_EDITION  Edition suffix                       (ee)
#   PG_VERSION  Full PostgreSQL version for the build (17.10)
#   PKG_VERSION Mock package version prefix          ($PG_VERSION)
#   BASE        Base image                            (ubuntu:noble)
#   REPO_PORT   Host port for the mock repository     (8080)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PG_MAJOR="${PG_MAJOR:-17}"
PG_EDITION="${PG_EDITION:-ee}"
PG_VERSION="${PG_VERSION:-17.10}"
PKG_VERSION="${PKG_VERSION:-${PG_VERSION}}"
BASE="${BASE:-ubuntu:noble}"
REPO_PORT="${REPO_PORT:-8080}"

PKG="postgresql-${PG_MAJOR}${PG_EDITION}"
IMAGE_TAG="postgresql-${PG_MAJOR}${PG_EDITION}-mock:local"
COMPOSE="docker compose -f ${SCRIPT_DIR}/docker-compose.yml"

cleanup() {
  echo "==> Tearing down mock APT repository"
  PG_MAJOR="${PG_MAJOR}" PG_EDITION="${PG_EDITION}" PKG_VERSION="${PKG_VERSION}" \
    ${COMPOSE} down --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Starting mock APT repository (serving ${PKG}=${PKG_VERSION}*)"
PG_MAJOR="${PG_MAJOR}" PG_EDITION="${PG_EDITION}" PKG_VERSION="${PKG_VERSION}" \
  ${COMPOSE} up -d --build

echo "==> Waiting for the mock repository on http://localhost:${REPO_PORT}"
for _ in $(seq 1 30); do
  if curl -fsS "http://localhost:${REPO_PORT}/Packages" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS "http://localhost:${REPO_PORT}/Packages" >/dev/null

echo "==> Building image with PG_EDITION=${PG_EDITION} against the mock repository"
docker build \
  --network=host \
  --target minimal \
  --build-arg "BASE=${BASE}" \
  --build-arg "PG_VERSION=${PG_VERSION}" \
  --build-arg "PG_MAJOR=${PG_MAJOR}" \
  --build-arg "PG_EDITION=${PG_EDITION}" \
  --build-arg "PG_EDITION_REPO=http://localhost:${REPO_PORT}" \
  -t "${IMAGE_TAG}" \
  "${REPO_ROOT}"

echo "==> Verifying that ${PKG} was installed in the image"
MARKER="$(docker run --rm "${IMAGE_TAG}" cat "/usr/share/${PKG}/mock-marker")"
echo "    marker: ${MARKER}"

echo "PASS: end-to-end build with mock ${PKG} succeeded"
