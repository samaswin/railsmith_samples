# railsmith_samples

This repo contains multiple Rails apps that share the same local infrastructure (Postgres/Redis/RabbitMQ) via the root `docker-compose.yml`.

## Projects

- `service/`
- `service_domain/`

## Start shared infrastructure (recommended per project)

The root `docker-compose.yml` is **parameterized** so each app can choose its own DB name and (optionally) host ports.

### `service/`

From `railsmith_samples/service` in PowerShell:

```powershell
$env:POSTGRES_DB="service_development"
$env:POSTGRES_USER="aswin"
$env:POSTGRES_PASSWORD="aswin"
docker compose -f ..\docker-compose.yml up -d
```

### `service_domain/`

From `railsmith_samples/service_domain` in PowerShell:

```powershell
$env:POSTGRES_DB="service_domain_development"
$env:POSTGRES_USER="aswin"
$env:POSTGRES_PASSWORD="aswin"
docker compose -f ..\docker-compose.yml up -d
```

## Notes

- If you already have Postgres on `5432` or Redis on `6379`, override the published ports:

```powershell
$env:POSTGRES_PORT="5433"
$env:REDIS_PORT="6380"
docker compose -f ..\docker-compose.yml up -d
```

- RabbitMQ is optional. The management UI defaults to `http://localhost:15672` (guest/guest). You can override it with:
  - `RABBITMQ_MANAGEMENT_PORT`

