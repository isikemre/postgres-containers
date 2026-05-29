ARG BASE=ubuntu:24.04@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b
FROM $BASE AS minimal

ARG PG_VERSION
ARG PG_MAJOR
# Optional suffix appended to the PostgreSQL APT package name, e.g. set to "ee"
# to install "postgresql-16ee" instead of the official "postgresql-16" package.
# Leave empty to use the official PGDG packages.
ARG PG_EDITION=""
# Optional extra APT repository that ships the edition packages. Leave empty
# (the default) for production builds. It is intended ONLY for local end-to-end
# testing of the PG_EDITION flow against a mock repository (see test/mock-ee).
# When set, the repository is trusted without GPG verification ([trusted=yes]),
# so it MUST NOT be used with production or untrusted repositories.
ARG PG_EDITION_REPO=""

ENV PATH=$PATH:/usr/lib/postgresql/$PG_MAJOR/bin

RUN apt-get update && \
    apt-get install -y --no-install-recommends postgresql-common ca-certificates gnupg && \
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y -c "${PG_MAJOR}" && \
    if [ -n "${PG_EDITION_REPO}" ]; then \
      echo "deb [trusted=yes] ${PG_EDITION_REPO} ./" > /etc/apt/sources.list.d/pg-edition-mock.list && \
      apt-get update; \
    fi && \
    apt-get install -y --no-install-recommends -o Dpkg::::="--force-confdef" -o Dpkg::::="--force-confold" postgresql-common && \
    sed -ri 's/#(create_main_cluster) .*$/\1 = false/' /etc/postgresql-common/createcluster.conf && \
    apt-get install -y --no-install-recommends \
      libsasl2-modules libldap-common \
      -o Dpkg::::="--force-confdef" -o Dpkg::::="--force-confold" "postgresql-${PG_MAJOR}${PG_EDITION}=${PG_VERSION}*" && \
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
