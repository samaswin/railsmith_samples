# Railsmith sample smoke

Optional **non-Rails** scripts that exercise `Railsmith::Pipeline` and services the way a small app would, without shipping a full Rails skeleton in this repository.

## Checkout smoke

From the **gem root** (parent of this directory):

```bash
bundle exec ruby railsmith_sample/smoke/checkout_smoke.rb
```

Exit code is `0` when the sample pipeline completes successfully.

## Async nested writes — contract tests

Exercises the Railsmith async nested write path against ActiveJob's `:inline` and `:test` adapters. Runs entirely in-process; no external services required.

```bash
bundle exec rails runner test_railsmith.rb
```

## Async nested writes — real backend tests

Drives real queue backends: Sidekiq through Redis, DelayedJob/GoodJob/SolidQueue through Postgres rows, and Sneakers/Kicks through RabbitMQ. Each section preflights its service and skips cleanly when the backend isn't reachable.

Start the services:

```bash
docker compose up -d          # postgres, redis, rabbitmq
```

Install the gem-backed schemas (one-time; only for the backends you want to exercise):

```bash
bundle exec rails generate delayed_job:active_record
bundle exec rails generate good_job:install
bundle exec rails solid_queue:install
bundle exec rails db:migrate
```

Run the suite:

```bash
bundle exec rails runner test_railsmith_real_jobs.rb
```

Override service URLs if needed:

```bash
SIDEKIQ_REDIS_URL=redis://localhost:6380/0 \
RABBITMQ_URL=amqp://guest:guest@localhost:5672 \
  bundle exec rails runner test_railsmith_real_jobs.rb
```

Exit code is `0` when every non-skipped assertion passes.
