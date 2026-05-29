# Mock APT repository that serves a dummy PostgreSQL edition package
# (e.g. postgresql-17ee) over HTTP for local end-to-end build testing.
FROM ubuntu:noble

RUN apt-get update && \
    apt-get install -y --no-install-recommends dpkg-dev gzip python3 && \
    rm -rf /var/lib/apt/lists/*

# Build-time configuration of the dummy package. These default to the values
# used by the docker-compose service and can be overridden if needed.
ARG PG_MAJOR=17
ARG PG_EDITION=ee
ARG PKG_VERSION=17.10

ENV REPO_DIR=/repo

COPY build-repo.sh /usr/local/bin/build-repo.sh
RUN chmod +x /usr/local/bin/build-repo.sh && \
    PG_MAJOR="${PG_MAJOR}" PG_EDITION="${PG_EDITION}" PKG_VERSION="${PKG_VERSION}" \
      /usr/local/bin/build-repo.sh

EXPOSE 8080
CMD ["python3", "-m", "http.server", "8080", "--directory", "/repo"]
