# Pinned to bookworm: the PGDG apt repo line below targets bookworm-pgdg, and the bare `slim` tag has
# rolled forward to trixie (Debian 13), whose libldap can't satisfy the bookworm libpq5 dependency.
FROM python:3.12-slim-bookworm

# postgresql-client-16 (pg_dump/pg_restore for admin backups) from the PGDG apt repo — the Debian
# bookworm default client is 15, which can't dump a Postgres 16 server.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates gnupg \
    && install -d /usr/share/postgresql-common/pgdg \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
         -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends postgresql-client-16 \
    && apt-get purge -y --auto-remove gnupg \
    && rm -rf /var/lib/apt/lists/*

# uv for fast, reproducible installs
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

# Install dependencies first for layer caching
COPY pyproject.toml ./
RUN uv pip install --system --no-cache .

COPY . .

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
