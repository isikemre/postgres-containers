# Local end-to-end test for PostgreSQL edition (`ee`) builds

This harness lets you exercise the configurable PostgreSQL edition build flow
(the `pgEdition` / `PG_EDITION` knob) **fully locally**, without access to a real
enterprise APT repository.

It works by mocking the missing piece: it builds a dummy
`postgresql-<major><edition>` package (for example `postgresql-17ee`) and serves
it from a small flat APT repository over HTTP. The repository image build is then
pointed at that mock repository, so it can resolve and install the edition
package exactly the way it would against a real enterprise repository.

> **Note:** Only the edition package is mocked. The base PostgreSQL tooling is
> still installed from the official PGDG repository (`apt.postgresql.org`), so
> the build host needs network access to it. The mock package is a placeholder
> that ships a marker file only — it contains no PostgreSQL binaries.

## Layout

| File | Purpose |
| --- | --- |
| `docker-compose.yml` | Defines the `apt-repo` service that serves the mock repository. |
| `apt-repo/Dockerfile` | Builds the mock repository image. |
| `apt-repo/build-repo.sh` | Generates the dummy `.deb` and flat APT metadata. |
| `run-test.sh` | One-shot end-to-end test (build + assertion). |

## Quick start

From the repository root:

```bash
./test/mock-ee/run-test.sh
```

This will:

1. Build and start the `apt-repo` service, serving `postgresql-17ee` on
   `http://localhost:8080`.
2. Build the `minimal` target of the repository `Dockerfile` with
   `PG_EDITION=ee` and `PG_EDITION_REPO` pointing at the mock repository.
3. Assert that `postgresql-17ee` was installed by reading the marker file it
   ships.
4. Tear the mock repository down.

You can override the defaults with environment variables, for example to test a
different major version or edition suffix:

```bash
PG_MAJOR=16 PG_VERSION=16.14 PG_EDITION=ee ./test/mock-ee/run-test.sh
```

## Running the mock repository on its own

If you want to drive the build yourself (for example through `docker buildx
bake`), start just the repository:

```bash
docker compose -f test/mock-ee/docker-compose.yml up -d --build
```

Then build with the mock repository wired in via the `pgEditionRepo` Bake
variable. The build needs to reach `localhost:8080`, so run it on the host
network:

```bash
pgEdition=ee pgEditionRepo=http://localhost:8080 \
  docker buildx bake \
    --set "*.platform=linux/amd64" \
    --set "*.network=host" \
    --set "*.output=type=docker" \
    postgresql-17-minimal-noble
```

Tear it down when finished:

```bash
docker compose -f test/mock-ee/docker-compose.yml down
```

## How the build hook works

The repository `Dockerfile` accepts an optional `PG_EDITION_REPO` build
argument. It is empty by default, so production builds are unaffected. When set,
it registers an extra (trusted) flat APT source before the PostgreSQL packages
are installed:

```dockerfile
ARG PG_EDITION_REPO=""
RUN ... && \
    if [ -n "${PG_EDITION_REPO}" ]; then \
      echo "deb [trusted=yes] ${PG_EDITION_REPO} ./" > /etc/apt/sources.list.d/pg-edition-mock.list && \
      apt-get update; \
    fi && \
    ...
```

The same argument is exposed through the `pgEditionRepo` variable in
`docker-bake.hcl`.
