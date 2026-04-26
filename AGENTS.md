## RailSmith Samples — Agent Operating Instructions

These are **required defaults** for any agent working in this repo. Follow them **without asking** unless there is a hard blocker.

### Environment (Windows host + WSL + asdf)
- **Use WSL** for Ruby/Rails work (do not run Rails/Bundler on native Windows Ruby).
- **Use asdf** for Ruby version management.
- The `service/` app pins Ruby via `service/.tool-versions` and `service/.ruby-version`.

#### WSL sanity check (before running any Ruby commands)
If `ruby` or `bundle` resolves to a Windows path like `/mnt/c/...`, your WSL PATH is leaking Windows executables.
Fix that first, otherwise Bundler/Rails will fail.

Recommended fix:

1) In WSL, set `/etc/wsl.conf`:

```ini
[interop]
appendWindowsPath=false
```

2) In PowerShell:

```powershell
wsl --shutdown
```

#### Required setup commands (WSL)
Run from WSL:

```bash
cd /mnt/c/Users/aswin/Git/railsmith_samples/service

# asdf ruby (assumes asdf is installed & initialized)
asdf plugin add ruby https://github.com/asdf-vm/asdf-ruby.git || true
asdf install
asdf current

# bundler version must match Gemfile.lock
gem install bundler -v 4.0.6
bundle _4.0.6_ install
```

### Databases (docker-compose Postgres)
This repo uses Postgres in docker-compose. In WSL, Rails must connect via **TCP** (not unix sockets).

#### Start Postgres (WSL)
From repo root:

```bash
cd /mnt/c/Users/aswin/Git/railsmith_samples
docker compose up -d postgres
```

#### Migrate (WSL)
Always run migrations with explicit env vars (or ensure they are exported):

```bash
cd /mnt/c/Users/aswin/Git/railsmith_samples/service

POSTGRES_HOST=127.0.0.1 \
POSTGRES_PORT=5432 \
POSTGRES_USER=aswin \
POSTGRES_PASSWORD=aswin \
POSTGRES_DB=service_development \
bundle exec rails db:migrate
```

Notes:
- `docker-compose.yml` defaults `POSTGRES_DB` to `app_development`. Prefer setting `POSTGRES_DB=service_development` when starting the container, or pass `POSTGRES_DB` when running Rails tasks.

### Local gem development (railsmith)
When using the local `railsmith` checkout, **do not hardcode Windows absolute paths**.

- Use a **relative** bundler path in `service/Gemfile`, e.g. `gem "railsmith", path: "../../railsmith"`.

### Migrations (strong_migrations required)
- If you add/modify any DB migrations, **ensure strong_migrations is installed and configured**, and the migration is compatible.
- `service/config/initializers/strong_migrations.rb` must `require "strong_migrations"` if the gem is declared with `require: false`.

### Linting / formatting requirements
This repo is a **demo**; do not run/enforce RuboCop/ESLint unless the USER explicitly asks.

### Project conventions
- Do not introduce odd variable names like `singular_string`. Use Rails/JS conventional naming.
- For time-related Rails specs, use `timecop` (install only if missing).

