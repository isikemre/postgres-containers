# Local end-to-end test for PostgreSQL edition (`ee`) builds

This harness lets you exercise the configurable PostgreSQL edition build flow
(the `pgEdition` / `PG_EDITION` knob) **fully locally**, without access to a real
enterprise APT repository.

It works by mocking the missing piece: it builds a dummy
`postgresql-<major><edition>` package (for example `postgresql-17ee`), signs it
with a throwaway GPG key, and serves it from a small flat APT repository over
HTTP. The repository `Dockerfile` build is then pointed at that mock repository
by injecting the generated `.sources` file and keyring as **BuildKit secret
mounts** — exactly the way a real enterprise repository would be configured.

> **Note:** Only the edition package is mocked. The base PostgreSQL tooling is
> still installed from the official PGDG repository (`apt.postgresql.org`), so
> the build host needs network access to it. The mock package is a placeholder
> that ships a marker file only — it contains no PostgreSQL binaries.

## Layout

| File | Purpose |
| --- | --- |
| `docker-compose.yml` | Defines the `apt-repo` service that serves the mock repository. |
| `apt-repo/Dockerfile` | Builds the mock repository image (package + GPG key + signing). |
| `apt-repo/build-repo.sh` | Generates the dummy `.deb`, GPG keyring, signed APT metadata, and `.sources` files. |
| `run-test.sh` | One-shot end-to-end test (build + assertion). |

## Quick start

From the repository root:

```bash
./test/mock-ee/run-test.sh
```

This will:

1. Build and start the `apt-repo` service, serving `postgresql-17ee` on
   `http://localhost:8080`.
2. Extract the generated `.sources` file and GPG keyring from the container.
3. Build the `minimal` target of the repository `Dockerfile` with
   `PG_EDITION=ee`, injecting the `.sources` and keyring as BuildKit secrets.
4. Assert that `postgresql-17ee` was installed by reading the marker file it
   ships.
5. Tear the mock repository down.

### Testing with an inline Signed-By key

The mock harness also generates a `.sources` file that embeds the signing key
inline, so no separate keyring file is needed. To exercise that path:

```bash
USE_INLINE_KEY=1 ./test/mock-ee/run-test.sh
```

### Overriding defaults

```bash
PG_MAJOR=16 PG_VERSION=16.14 PG_EDITION=ee ./test/mock-ee/run-test.sh
```

## Running the mock repository on its own

If you want to drive the build yourself (for example through `docker buildx
bake`), start just the repository:

```bash
docker compose -f test/mock-ee/docker-compose.yml up -d --build
```

Extract the secrets from the running container:

```bash
CONTAINER_ID=$(docker compose -f test/mock-ee/docker-compose.yml ps -q apt-repo)
docker cp "$CONTAINER_ID:/repo/mock-ee.sources"  ./mock-ee.sources
docker cp "$CONTAINER_ID:/repo/vendor.gpg"        ./vendor.gpg
```

Then build with the Bake variables pointing at the extracted files:

```bash
pgEdition=ee \
pgEditionSources1=./mock-ee.sources \
pgEditionKeyring=./vendor.gpg \
  docker buildx bake \
    --set "*.platform=linux/amd64" \
    --set "*.output=type=docker" \
    postgresql-17-minimal-noble
```

Or with plain `docker buildx build`:

```bash
docker build \
  --add-host=host.docker.internal:host-gateway \
  --target minimal \
  --build-arg PG_EDITION=ee \
  --build-arg PG_VERSION=17.10 \
  --build-arg PG_MAJOR=17 \
  --secret id=pg_edition_sources1,src=./mock-ee.sources \
  --secret id=pg_edition_keyring,src=./vendor.gpg \
  .
```

Tear it down when finished:

```bash
docker compose -f test/mock-ee/docker-compose.yml down
```

## How the build hook works

The repository `Dockerfile` uses **BuildKit secret mounts** to inject APT
configuration for the edition repository. Three optional secrets are supported:

| Secret ID | Purpose |
| --- | --- |
| `pg_edition_sources1` | First deb822 `.sources` file |
| `pg_edition_sources2` | Second deb822 `.sources` file |
| `pg_edition_keyring` | GPG keyring referenced by `Signed-By:` in a `.sources` file |

Secrets are only used when provided; the default (empty) build works exactly
as before. The relevant section of the `Dockerfile`:

```dockerfile
RUN --mount=type=secret,id=pg_edition_sources1,required=false \
    --mount=type=secret,id=pg_edition_sources2,required=false \
    --mount=type=secret,id=pg_edition_keyring,required=false \
    set -eux && \
    ... \
    if [ -f /run/secrets/pg_edition_keyring ]; then \
      cp /run/secrets/pg_edition_keyring /usr/share/keyrings/pg-edition.gpg; \
      chmod a+r /usr/share/keyrings/pg-edition.gpg; \
    fi && \
    if [ -f /run/secrets/pg_edition_sources1 ]; then \
      cp /run/secrets/pg_edition_sources1 /etc/apt/sources.list.d/pg-edition-1.sources; \
      chmod a+r /etc/apt/sources.list.d/pg-edition-1.sources; \
    fi && \
    ...
```

> **Note:** BuildKit mounts secret files with mode `0400` (root-only). The
> copied keyring and `.sources` files are therefore made world-readable with
> `chmod a+r`, otherwise apt's unprivileged `_apt` sandbox user cannot read the
> keyring and verification fails with `NO_PUBKEY ... is not signed`.

After installing the edition package, the injected files are removed so they
never appear in the final image.

The same secrets are exposed through `docker-bake.hcl` variables:
`pgEditionSources1`, `pgEditionSources2`, and `pgEditionKeyring`.

## Inline vs. external keyring

APT deb822 `.sources` files support two modes for `Signed-By`:

1. **External keyring** — `Signed-By: /usr/share/keyrings/pg-edition.gpg`  
   Pass the keyring as `pg_edition_keyring`.

2. **Inline key** — the public key block is embedded directly in the `.sources`
   file after `Signed-By:`.  
   No separate keyring is needed; only pass `pg_edition_sources1`.

The mock harness generates both variants (`mock-ee.sources` and
`mock-ee-inline.sources`) so you can test either path.
