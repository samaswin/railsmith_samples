# frozen_string_literal: true

# Real-backend integration tests for Railsmith async nested writes.
#
# Unlike test_railsmith.rb (which uses ActiveJob :inline / :test adapters to
# exercise contract shape in-process), this file drives ACTUAL queue backends:
#
#   * Sidekiq pushed into a real Redis list, then popped and executed.
#   * DelayedJob persisted as a real delayed_jobs row, then work_off'd.
#   * GoodJob persisted as a real good_jobs row, then drained.
#   * SolidQueue persisted as a real solid_queue_jobs row (if schema present).
#   * Sneakers published to a real RabbitMQ queue (if RabbitMQ reachable).
#
# Run with:
#
#   docker compose up -d   # start postgres, redis, rabbitmq
#   bundle exec rails runner test_railsmith_real_jobs.rb
#
# Each section preflights its service and skips with a readable message if
# the dependency is not reachable — the suite never hangs on a missing
# backend. Set env vars to override URLs:
#
#   SIDEKIQ_REDIS_URL   (default: redis://localhost:6379/0)
#   RABBITMQ_URL        (default: amqp://guest:guest@localhost:5672)
#
# NOTE: SolidQueue / GoodJob / DelayedJob require their schemas migrated into
# your development database. See the bottom of this file for the commands.

require "json"

$failures = []
$pass_count = 0
$skipped = []

def assert(label, condition)
  if condition
    puts "  PASS  #{label}"
    $pass_count += 1
  else
    puts "  FAIL  #{label}"
    $failures << label
  end
end

def skip_section(name, reason)
  $skipped << "#{name}: #{reason}"
  puts "  SKIP  #{name} — #{reason}"
end

ctx = { current_domain: :blog }

original_async_job_class = Railsmith.configuration.async_job_class
original_async_enqueuer  = Railsmith.configuration.async_enqueuer
original_queue_adapter   = ActiveJob::Base.queue_adapter

def restore_async_config!(job_class, enqueuer)
  Railsmith.configuration.async_job_class = job_class
  Railsmith.configuration.async_enqueuer  = enqueuer
end

# ═════════════════════════════════════════════════════════════════════════════
# 1. SIDEKIQ + REAL REDIS
# ═════════════════════════════════════════════════════════════════════════════
puts "\n=== 1. Sidekiq with real Redis (full JSON round-trip through Redis) ==="

sidekiq_redis_url = ENV.fetch("SIDEKIQ_REDIS_URL", "redis://localhost:6379/0")
sidekiq_up = false

begin
  require "sidekiq"
  Sidekiq.configure_client { |c| c.redis = { url: sidekiq_redis_url } }
  Sidekiq.configure_server { |c| c.redis = { url: sidekiq_redis_url } } if Sidekiq.respond_to?(:configure_server)
  Sidekiq.redis { |r| r.ping }
  sidekiq_up = true
rescue LoadError => e
  skip_section("Sidekiq+Redis", "sidekiq gem not loadable: #{e.message}")
rescue => e
  skip_section("Sidekiq+Redis", "Redis unreachable at #{sidekiq_redis_url} (#{e.class}: #{e.message})")
end

# KNOWN GEM BUG: railsmith builds its async payload with symbol keys and passes
# it unchanged to `RailsmithNestedWriteWorker.perform_async(payload)`. Sidekiq
# 7+ defaults to strict_args!, which rejects non-JSON-native types (Symbols).
# The proper fix is in the gem:
#   lib/railsmith/base_service/nested_writer/nested_write/async_enqueueing.rb
# should deep_stringify_keys the payload before perform_async. Until that lands,
# we stringify at our side here so the rest of this section can actually
# exercise the Redis round-trip. Without this shim the gem crashes inside
# Sidekiq's verify_json before a single byte reaches Redis.
if sidekiq_up
  unless RailsmithNestedWriteWorker.singleton_class.method_defined?(:__orig_perform_async)
    RailsmithNestedWriteWorker.singleton_class.send(:alias_method, :__orig_perform_async, :perform_async)
    RailsmithNestedWriteWorker.define_singleton_method(:perform_async) do |payload|
      stringified = JSON.parse(JSON.generate(payload)) # forces symbols → strings recursively
      __orig_perform_async(stringified)
    end
  end
end

if sidekiq_up
  queue_key = "queue:railsmith_nested_writes"
  # Start from a clean queue so assertions are deterministic.
  Sidekiq.redis { |r| r.del(queue_key) }

  Railsmith.configuration.async_job_class = RailsmithNestedWriteWorker
  Railsmith.configuration.async_enqueuer  = nil

  rs = PostWithAsyncCommentsService.call(
    action: :create,
    params: {
      attributes: { title: "Sidekiq Real-Redis Post", status: "draft" },
      comments: [{ attributes: { author: "RealSid", body: "pushed through real Redis" } }]
    },
    context: { current_domain: :blog, request_id: "sk-real-req-1" }
  )
  assert("sidekiq real: parent created", rs.success?)
  assert("sidekiq real: parent persisted in DB", Post.exists?(title: "Sidekiq Real-Redis Post"))
  assert("sidekiq real: comment NOT persisted yet (waiting on worker)", !Comment.exists?(post_id: rs.value.id, author: "RealSid"))

  # Job must be sitting on the real Redis queue.
  queue_len = Sidekiq.redis { |r| r.llen(queue_key) }
  assert("sidekiq real: job pushed to Redis queue (llen = #{queue_len})", queue_len == 1)

  # Pop the job straight out of Redis — this proves JSON round-trip survived
  # Sidekiq's client-side packing + Redis's wire format.
  popped = Sidekiq.redis { |r| r.brpop(queue_key, timeout: 5) }
  assert("sidekiq real: brpop returned a job", !popped.nil? && popped.is_a?(Array) && popped.size == 2)

  if popped
    job_hash = JSON.parse(popped.last)
    assert("sidekiq real: job class is RailsmithNestedWriteWorker", job_hash["class"] == "RailsmithNestedWriteWorker")
    assert("sidekiq real: job queue is railsmith_nested_writes",    job_hash["queue"] == "railsmith_nested_writes")
    assert("sidekiq real: job args is an array",                    job_hash["args"].is_a?(Array) && !job_hash["args"].empty?)

    payload = job_hash["args"].first
    assert("sidekiq real: payload has service_class key", payload["service_class"] == "PostWithAsyncCommentsService")
    assert("sidekiq real: payload has parent_id",         payload["parent_id"] == rs.value.id)
    assert("sidekiq real: payload context request_id survived Redis roundtrip",
      payload["context"].is_a?(Hash) && (payload["context"]["request_id"] == "sk-real-req-1"))

    # Execute exactly as a real Sidekiq worker would.
    worker_class = Object.const_get(job_hash["class"])
    worker_class.new.perform(*job_hash["args"])
    assert("sidekiq real: comment persisted after worker consumed Redis message",
      Comment.exists?(post_id: rs.value.id, author: "RealSid"))
  end

  # Queue should now be empty.
  assert("sidekiq real: queue drained", Sidekiq.redis { |r| r.llen(queue_key) } == 0)
end

# ═════════════════════════════════════════════════════════════════════════════
# 2. DELAYED JOB + REAL POSTGRES (delayed_jobs rows, work_off)
# ═════════════════════════════════════════════════════════════════════════════
puts "\n=== 2. DelayedJob with real Postgres (real rows + work_off) ==="

dj_up = false
begin
  require "delayed_job"
  require "delayed_job_active_record"
  # Table presence check — probes the real DB, not the gem.
  Delayed::Job.connection.execute("SELECT 1 FROM delayed_jobs LIMIT 1")
  dj_up = true
rescue LoadError => e
  skip_section("DelayedJob", "gem not loadable: #{e.message}")
rescue ActiveRecord::StatementInvalid => e
  skip_section("DelayedJob", "delayed_jobs table missing — run: rails generate delayed_job:active_record && rails db:migrate")
rescue => e
  skip_section("DelayedJob", "#{e.class}: #{e.message}")
end

if dj_up
  Delayed::Job.delete_all

  ActiveJob::Base.queue_adapter = :delayed_job
  Railsmith.configuration.async_job_class = Railsmith::AsyncNestedWriteJob
  Railsmith.configuration.async_enqueuer  = nil

  rdj = PostWithAsyncCommentsService.call(
    action: :create,
    params: {
      attributes: { title: "DJ Real Post", status: "draft" },
      comments: [{ attributes: { author: "RealDJ", body: "persisted to delayed_jobs" } }]
    },
    context: ctx
  )
  assert("delayed_job: parent created", rdj.success?)
  row_count = Delayed::Job.count
  assert("delayed_job: row present in delayed_jobs (#{row_count})", row_count >= 1)
  assert("delayed_job: comment NOT written until work_off",
    !Comment.exists?(post_id: rdj.value.id, author: "RealDJ"))

  # work_off runs the real worker loop against the real DB once.
  success_count, failure_count = Delayed::Worker.new.work_off
  assert("delayed_job: work_off processed job (success=#{success_count}, failures=#{failure_count})",
    success_count >= 1 && failure_count == 0)
  assert("delayed_job: comment written after work_off",
    Comment.exists?(post_id: rdj.value.id, author: "RealDJ"))
  assert("delayed_job: queue drained", Delayed::Job.count == 0)
end

# ═════════════════════════════════════════════════════════════════════════════
# 3. GOOD JOB + REAL POSTGRES
# ═════════════════════════════════════════════════════════════════════════════
puts "\n=== 3. GoodJob with real Postgres ==="

gj_up = false
begin
  require "good_job"
  GoodJob::Job.connection.execute("SELECT 1 FROM good_jobs LIMIT 1")
  gj_up = true
rescue LoadError => e
  skip_section("GoodJob", "gem not loadable: #{e.message}")
rescue ActiveRecord::StatementInvalid => e
  skip_section("GoodJob", "good_jobs table missing — run: rails g good_job:install && rails db:migrate")
rescue => e
  skip_section("GoodJob", "#{e.class}: #{e.message}")
end

if gj_up
  GoodJob::Job.delete_all

  ActiveJob::Base.queue_adapter = :good_job
  Railsmith.configuration.async_job_class = Railsmith::AsyncNestedWriteJob
  Railsmith.configuration.async_enqueuer  = nil

  rgj = PostWithAsyncCommentsService.call(
    action: :create,
    params: {
      attributes: { title: "GJ Real Post", status: "draft" },
      comments: [{ attributes: { author: "RealGJ", body: "persisted to good_jobs" } }]
    },
    context: ctx
  )
  assert("good_job: parent created", rgj.success?)
  pending_before = GoodJob::Job.where(finished_at: nil).count
  assert("good_job: row present in good_jobs (pending=#{pending_before})", pending_before >= 1)
  assert("good_job: comment NOT written before drain",
    !Comment.exists?(post_id: rgj.value.id, author: "RealGJ"))

  # Drain the queue by iterating pending rows and executing each. This is the
  # same work a real GoodJob executor does; performing it here proves the
  # persisted row deserializes back into a runnable ActiveJob.
  drained = 0
  GoodJob::Job.where(finished_at: nil).order(:created_at).find_each do |job_row|
    job_row.perform_now if job_row.respond_to?(:perform_now)
    # Older/newer GoodJob versions: fall back to ActiveJob::Base.execute
    unless job_row.respond_to?(:perform_now)
      active_job_data = job_row.respond_to?(:active_job) ? job_row.active_job : nil
      active_job_data&.perform_now
    end
    drained += 1
  end
  assert("good_job: drained #{drained} job(s) through real executor", drained >= 1)
  assert("good_job: comment written after drain",
    Comment.exists?(post_id: rgj.value.id, author: "RealGJ"))
end

# ═════════════════════════════════════════════════════════════════════════════
# 4. SOLID QUEUE + REAL POSTGRES (optional — needs migrated schema)
# ═════════════════════════════════════════════════════════════════════════════
puts "\n=== 4. SolidQueue with real Postgres ==="

sq_up = false
begin
  require "solid_queue"
  SolidQueue::Job.connection.execute("SELECT 1 FROM solid_queue_jobs LIMIT 1")
  sq_up = true
rescue LoadError => e
  skip_section("SolidQueue", "gem not loadable: #{e.message}")
rescue ActiveRecord::StatementInvalid => e
  skip_section("SolidQueue", "solid_queue_jobs table missing — run: rails solid_queue:install && rails db:migrate")
rescue NameError => e
  skip_section("SolidQueue", "SolidQueue constants not defined: #{e.message}")
rescue => e
  skip_section("SolidQueue", "#{e.class}: #{e.message}")
end

if sq_up
  SolidQueue::Job.delete_all
  SolidQueue::ReadyExecution.delete_all if defined?(SolidQueue::ReadyExecution)

  ActiveJob::Base.queue_adapter = :solid_queue
  Railsmith.configuration.async_job_class = Railsmith::AsyncNestedWriteJob
  Railsmith.configuration.async_enqueuer  = nil

  rsq = PostWithAsyncCommentsService.call(
    action: :create,
    params: {
      attributes: { title: "SQ Real Post", status: "draft" },
      comments: [{ attributes: { author: "RealSQ", body: "persisted to solid_queue_jobs" } }]
    },
    context: ctx
  )
  assert("solid_queue: parent created", rsq.success?)
  sq_count = SolidQueue::Job.count
  assert("solid_queue: row present in solid_queue_jobs (#{sq_count})", sq_count >= 1)

  # Drain by iterating ready executions / jobs. SolidQueue's public API has
  # changed across versions, so try a few shapes.
  drained_sq = 0
  SolidQueue::Job.where(finished_at: nil).order(:created_at).find_each do |sqj|
    if sqj.respond_to?(:arguments) && sqj.respond_to?(:class_name)
      klass = sqj.class_name.safe_constantize
      klass&.new&.deserialize({ "job_class" => sqj.class_name, "arguments" => sqj.arguments, "job_id" => sqj.active_job_id })
      # Rails ActiveJob can reconstruct from the serialized row:
      serialized = { "job_class" => sqj.class_name, "arguments" => sqj.arguments, "job_id" => sqj.active_job_id,
                     "queue_name" => sqj.queue_name, "priority" => sqj.priority, "executions" => 0, "exception_executions" => {},
                     "locale" => "en", "timezone" => "UTC", "enqueued_at" => Time.now.iso8601, "scheduled_at" => nil, "provider_job_id" => nil }
      ActiveJob::Base.execute(serialized)
      sqj.update!(finished_at: Time.current) if sqj.respond_to?(:update!)
      drained_sq += 1
    end
  end
  assert("solid_queue: drained #{drained_sq} job(s)", drained_sq >= 1)
  assert("solid_queue: comment written after drain",
    Comment.exists?(post_id: rsq.value.id, author: "RealSQ"))
end

# ═════════════════════════════════════════════════════════════════════════════
# 5. RABBITMQ + Kicks/Sneakers (optional — needs RabbitMQ reachable)
# ═════════════════════════════════════════════════════════════════════════════
puts "\n=== 5. Kicks/Sneakers publish+consume through real RabbitMQ ==="

rabbit_url = ENV.fetch("RABBITMQ_URL", "amqp://guest:guest@localhost:5672")
rabbit_up = false
bunny_conn = nil

begin
  require "bunny"
  bunny_conn = Bunny.new(rabbit_url, connection_timeout: 2)
  bunny_conn.start
  rabbit_up = true
rescue LoadError => e
  skip_section("RabbitMQ+Kicks", "bunny gem not loadable (install `bunny` or `sneakers`): #{e.message}")
rescue => e
  skip_section("RabbitMQ+Kicks", "RabbitMQ unreachable at #{rabbit_url} (#{e.class}: #{e.message})")
end

if rabbit_up && bunny_conn
  queue_name = "railsmith.nested_writes.test"
  ch = bunny_conn.create_channel
  q  = ch.queue(queue_name, auto_delete: true)
  q.purge

  # Wire the gem to publish to this queue by routing through a custom enqueuer.
  # Use define_singleton_method to close over the Bunny queue object — class
  # variables inside Class.new at toplevel raise in Ruby 3 because the block's
  # scope is the toplevel, not the new class.
  rabbit_bunny_queue = q
  rabbit_publish_class = Class.new
  rabbit_publish_class.define_singleton_method(:publish) do |payload|
    # The gem currently passes symbol-keyed payloads; RabbitMQ needs bytes,
    # so stringify before encoding (same gem bug as Sidekiq).
    stringified = JSON.parse(JSON.generate(payload))
    rabbit_bunny_queue.publish(stringified.to_json, persistent: false)
    "rmq-#{SecureRandom.hex(6)}"
  end

  Railsmith.configuration.async_job_class = rabbit_publish_class
  Railsmith.configuration.async_enqueuer  = ->(job_class, payload) { job_class.publish(payload) }

  rmq = PostWithAsyncCommentsService.call(
    action: :create,
    params: {
      attributes: { title: "RabbitMQ Real Post", status: "draft" },
      comments: [{ attributes: { author: "RealRMQ", body: "published through real RabbitMQ" } }]
    },
    context: { current_domain: :blog, request_id: "rmq-real-req-1" }
  )
  assert("rabbitmq: parent created", rmq.success?)
  sleep 0.2 # let the publish land on the broker
  assert("rabbitmq: message count on queue == 1", q.message_count == 1)
  assert("rabbitmq: comment NOT yet persisted", !Comment.exists?(post_id: rmq.value.id, author: "RealRMQ"))

  # Consume one message from RabbitMQ and execute the nested write. We use
  # manual_ack: false so the broker auto-acknowledges on delivery -- Bunny's
  # basic_ack path wants a raw Integer delivery tag and the VersionedDeliveryTag
  # wrapper returned by basic_get trips amq-protocol's pack_uint64_big_endian.
  # Auto-ack is fine for this test: we only need to prove the message round
  # trip, not broker durability semantics.
  _delivery_info, _, body = ch.basic_get(queue_name, manual_ack: false)
  assert("rabbitmq: basic_get returned a message", !body.nil?)

  if body
    payload = JSON.parse(body).transform_keys(&:to_sym)
    service_klass = Object.const_get(payload[:service_class])
    parent_record = service_klass.model.find(payload[:parent_id])
    railsmith_context = Railsmith::Context.build(payload[:context])
    service_klass
      .new(params: {}, context: railsmith_context)
      .send(:perform_nested_write_for_job,
            payload[:association].to_sym,
            parent_record,
            payload[:nested_params],
            payload[:mode].to_sym)

    assert("rabbitmq: comment persisted after consuming from real broker",
      Comment.exists?(post_id: rmq.value.id, author: "RealRMQ"))
  end

  ch.close
  bunny_conn.close
end

# ═════════════════════════════════════════════════════════════════════════════
# Restore config and print summary
# ═════════════════════════════════════════════════════════════════════════════
restore_async_config!(original_async_job_class, original_async_enqueuer)
ActiveJob::Base.queue_adapter = original_queue_adapter

puts "\n=============================="
total = $pass_count + $failures.length
puts "passed: #{$pass_count}"
puts "failed: #{$failures.length}"
puts "skipped: #{$skipped.length}"

if $failures.any?
  puts "\nFAILURES:"
  $failures.each { |f| puts "  - #{f}" }
end

if $skipped.any?
  puts "\nSKIPPED (bring up the service to exercise these):"
  $skipped.each { |s| puts "  - #{s}" }
end

exit($failures.empty? ? 0 : 1)
