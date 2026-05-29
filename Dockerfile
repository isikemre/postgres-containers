ARG BASE=ubuntu:24.04@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b
FROM $BASE AS minimal

ARG PG_VERSION
ARG PG_MAJOR
# Optional suffix appended to the PostgreSQL APT package name, e.g. set to "ee"
# to install "postgresql-16ee" instead of the official "postgresql-16" package.
# Leave empty to use the official PGDG packages.
ARG PG_EDITION=""

ENV PATH=$PATH:/usr/lib/postgresql/$PG_MAJOR/bin

# The edition APT sources and keyring are injected via BuildKit secret mounts
# so they never leak into the image history. Three optional secrets are
# supported:
#
#   pg_edition_sources1  – first  deb822 .sources file
#   pg_edition_sources2  – second deb822 .sources file
#   pg_edition_keyring   – GPG keyring referenced by Signed-By in a .sources
#
# Only the secrets that are actually provided are installed. Sources that embed
# the signing key inline (Signed-By: + BEGIN PGP PUBLIC KEY BLOCK) do not need
# the keyring. After the edition package is installed every injected file is
# removed so the final image stays clean.
#
# Usage with plain docker build:
#   docker build \
#     --secret id=pg_edition_sources1,src=vendor-main.sources \
#     --secret id=pg_edition_sources2,src=vendor-updates.sources \
#     --secret id=pg_edition_keyring,src=vendor.gpg \
#     --build-arg PG_EDITION=ee ...
#
# Usage with docker buildx bake: see the secret block in docker-bake.hcl.

RUN --mount=type=secret,id=pg_edition_sources1,required=false \
    --mount=type=secret,id=pg_edition_sources2,required=false \
    --mount=type=secret,id=pg_edition_keyring,required=false \
    set -eux && \
    apt-get update && \
    apt-get install -y --no-install-recommends postgresql-common ca-certificates gnupg && \
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y -c "${PG_MAJOR}" && \
    if [ -f /run/secrets/pg_edition_keyring ]; then \
      cp /run/secrets/pg_edition_keyring /usr/share/keyrings/pg-edition.gpg; \
      chmod a+r /usr/share/keyrings/pg-edition.gpg; \
    fi && \
    if [ -f /run/secrets/pg_edition_sources1 ]; then \
      cp /run/secrets/pg_edition_sources1 /etc/apt/sources.list.d/pg-edition-1.sources; \
      chmod a+r /etc/apt/sources.list.d/pg-edition-1.sources; \
    fi && \
    if [ -f /run/secrets/pg_edition_sources2 ]; then \
      cp /run/secrets/pg_edition_sources2 /etc/apt/sources.list.d/pg-edition-2.sources; \
      chmod a+r /etc/apt/sources.list.d/pg-edition-2.sources; \
    fi && \
    if [ -f /etc/apt/sources.list.d/pg-edition-1.sources ] || \
       [ -f /etc/apt/sources.list.d/pg-edition-2.sources ]; then \
      apt-get update; \
    fi && \
    apt-get install -y --no-install-recommends -o Dpkg::::="--force-confdef" -o Dpkg::::="--force-confold" postgresql-common && \
    sed -ri 's/#(create_main_cluster) .*$/\1 = false/' /etc/postgresql-common/createcluster.conf && \
    apt-get install -y --no-install-recommends \
      libsasl2-modules libldap-common \
      -o Dpkg::::="--force-confdef" -o Dpkg::::="--force-confold" "postgresql-${PG_MAJOR}${PG_EDITION}=${PG_VERSION}*" && \
    rm -f /etc/apt/sources.list.d/pg-edition-1.sources \
          /etc/apt/sources.list.d/pg-edition-2.sources \
          /usr/share/keyrings/pg-edition.gpg && \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false && \
    rm -rf /var/lib/apt/lists/* /var/cache/* /var/log/*

RUN usermod -u 26 postgres
USER 26


FROM minimal AS standard
ARG EXTENSIONS
ARG STANDARD_ADDITIONAL_POSTGRES_PACKAGES
USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends locales-all ${STANDARD_ADDITIONAL_POSTGRES_PACKAGES} ${EXTENSIONS} && \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false && \
    rm -rf /var/lib/apt/lists/* /var/cache/* /var/log/*

USER 26

FROM standard AS system
ARG BARMAN_VERSION

# We need to break the system packages to install barman-cloud on
# externally-managed environments such as Ubuntu 24.04 (and Debian bookworm and later)
ENV PIP_BREAK_SYSTEM_PACKAGES=1

USER root
RUN apt-get update && \
	apt-get install -y --no-install-recommends \
		# We require build-essential and python3-dev to build lz4 on arm64 since there isn't a pre-compiled wheel available
		build-essential python3-dev \
		python3-pip \
		python3-psycopg2 \
		python3-setuptools \
	&& \
	pip3 install --no-cache-dir barman[cloud,azure,snappy,google,zstandard,lz4]==${BARMAN_VERSION} && \
	python3 -c "import sysconfig, compileall; compileall.compile_dir(sysconfig.get_path('stdlib'), quiet=1); compileall.compile_dir(sysconfig.get_path('purelib'), quiet=1); compileall.compile_dir(sysconfig.get_path('platlib'), quiet=1)" && \
	apt-get remove -y --purge --autoremove build-essential python3-dev && \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false && \
	rm -rf /var/lib/apt/lists/* /var/cache/* /var/log/*

USER 26
