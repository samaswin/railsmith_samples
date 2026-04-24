# frozen_string_literal: true

# Run with: bundle exec rails runner test_railsmith.rb
#
# Full integration coverage of the Railsmith gem against a real Rails + Postgres app.

require "railsmith/arch_checks"

$failures = []
$pass_count = 0

def assert(label, condition)
  if condition
    puts "  PASS  #{label}"
    $pass_count += 1
  else
    puts "  FAIL  #{label}"
    $failures << label
  end
end

ctx = { current_domain: :blog }

# ── 1. CRUD ───────────────────────────────────────────────────────────────────
puts "\n=== 1. CRUD (PostService) ==="

r = PostService.call(action: :create, params: { attributes: { title: "Hello", status: "draft" } }, context: ctx)
assert("create valid", r.success? && r.value.title == "Hello")

r2 = PostService.call(action: :create, params: { attributes: { title: "", status: "draft" } }, context: ctx)
assert("create invalid (blank title) → failure", r2.failure?)
assert("create invalid → validation_error", r2.error.code == "validation_error")

r3 = PostService.call(action: :create, params: { attributes: { title: "T", status: "bogus" } }, context: ctx)
assert("create invalid (bad status via model) → failure", r3.failure?)

post = r.value

r4 = PostService.call(action: :find, params: { id: post.id }, context: ctx)
assert("find existing → success", r4.success? && r4.value.id == post.id)

r5 = PostService.call(action: :find, params: { id: 99_999 }, context: ctx)
assert("find missing → not_found", r5.failure? && r5.error.code == "not_found")

r6 = PostService.call(action: :find, params: {}, context: ctx)
assert("find without id → validation_error", r6.failure? && r6.error.code == "validation_error")

r7 = PostService.call(action: :list, params: {}, context: ctx)
assert("list → success + relation", r7.success? && r7.value.is_a?(ActiveRecord::Relation))

r8 = PostService.call(action: :update, params: { id: post.id, attributes: { title: "Updated", status: "published" } }, context: ctx)
assert("update → success, title changed", r8.success? && r8.value.title == "Updated")

r9 = PostService.call(action: :update, params: { attributes: { title: "X" } }, context: ctx)
assert("update without id → validation_error", r9.failure? && r9.error.code == "validation_error")

r10 = PostService.call(action: :destroy, params: { id: post.id }, context: ctx)
assert("destroy → success", r10.success?)
assert("destroy → record gone", !Post.exists?(post.id))

assert("invalid action → failure", PostService.call(action: :nonexistent, params: {}, context: ctx).failure?)

# ── 2. INPUT DSL ──────────────────────────────────────────────────────────────
puts "\n=== 2. INPUT DSL (PostFormService) ==="

rf1 = PostFormService.call(action: :create, params: { attributes: { title: "Form Post" } }, context: ctx)
assert("create with defaults", rf1.success? && rf1.value.status == "draft" && rf1.value.published == false && rf1.value.tag_list.nil?)

rf2 = PostFormService.call(action: :create, params: { attributes: {} }, context: ctx)
assert("required title missing → failure", rf2.failure? && rf2.error.code == "validation_error")

rf3 = PostFormService.call(action: :create, params: { attributes: { title: "T", status: "bogus" } }, context: ctx)
assert("in: constraint violation → failure", rf3.failure?)

rf4 = PostFormService.call(action: :create, params: { attributes: { title: "Tagged", tag_list: "  Ruby Rails  " } }, context: ctx)
assert("transform: strip+downcase", rf4.success? && rf4.value.tag_list == "ruby rails")

rf5 = PostFormService.call(action: :create, params: { attributes: { title: "Bool", published: "true" } }, context: ctx)
assert(":boolean coercion from string 'true'", rf5.success? && rf5.value.published == true)

rf6 = PostFormService.call(action: :create, params: { attributes: { title: "Bool0", published: "0" } }, context: ctx)
assert(":boolean coercion from string '0' → false", rf6.success? && rf6.value.published == false)

form_post = rf1.value

# filter_inputs false — undeclared keys pass through
filter_off_svc = Class.new(Railsmith::BaseService) do
  model Post
  filter_inputs false
  input :title, String, required: true
end
rf7 = filter_off_svc.call(action: :create, params: { attributes: { title: "Filter Off", body: "kept!" } }, context: ctx)
assert("filter_inputs false: undeclared :body passes through", rf7.success? && rf7.value.body == "kept!")

# Custom coercion applied via input type
money_svc = Class.new(Railsmith::BaseService) do
  input :price, :money, required: true
  def quote
    Railsmith::Result.success(value: { cents: params[:price] })
  end
end
rf8 = money_svc.call(action: :quote, params: { price: "9.99" }, context: ctx)
assert("custom :money coercion → 999 cents", rf8.success? && rf8.value[:cents] == 999)

# ── 3. CONTEXT ────────────────────────────────────────────────────────────────
puts "\n=== 3. Context ==="

probe_svc = Class.new(Railsmith::BaseService) do
  def probe
    Railsmith::Result.success(value: { domain: context.domain, request_id: context.request_id })
  end
end

# Thread-local context via Context.with
Railsmith::Context.with(domain: :web, request_id: "req-123") do
  result = probe_svc.call(action: :probe, params: {})
  assert("Context.with sets thread-local domain", result.value[:domain] == :web)
  assert("Context.with sets request_id", result.value[:request_id] == "req-123")
end

# Explicit context overrides thread-local
explicit_ctx = Railsmith::Context.new(domain: :explicit, request_id: "ex-1")
Railsmith::Context.with(domain: :thread_local, request_id: "tl-1") do
  result = probe_svc.call(action: :probe, params: {}, context: explicit_ctx)
  assert("explicit context overrides thread-local", result.value[:domain] == :explicit)
end

# Auto-generated request_id when none supplied
result = probe_svc.call(action: :probe, params: {}, context: {})
assert("auto request_id is a UUID", result.value[:request_id].match?(/\A[0-9a-f\-]{36}\z/))

# context isolation — mutations inside don't leak out
original_ctx = { actor: { id: 123 }, flags: %w[a b] }
mutation_svc = Class.new(Railsmith::BaseService) do
  def mutate
    context[:actor][:id] = 999
    context[:flags] << "c"
    Railsmith::Result.success(value: true)
  end
end
mutation_svc.call(action: :mutate, params: {}, context: original_ctx)
assert("context deep-duped — original not mutated", original_ctx[:actor][:id] == 123 && original_ctx[:flags] == %w[a b])

# ── 4. EAGER LOADING ──────────────────────────────────────────────────────────
puts "\n=== 4. Eager Loading ==="

p_el = Post.create!(title: "Eager Post", status: "draft")
Comment.create!(post_id: p_el.id, author: "Eve", body: "Hi")
Tag.create!(post_id: p_el.id, label: "ruby")

el_result = PostWithTagsService.call(action: :list, params: {}, context: ctx)
assert("includes: list returns success", el_result.success?)
record = el_result.value.to_a.find { |p| p.id == p_el.id }
assert("includes :tags preloaded on list", record.association(:tags).loaded?)
assert("includes :comments preloaded on list", record.association(:comments).loaded?)

el_find = PostWithTagsService.call(action: :find, params: { id: p_el.id }, context: ctx)
assert("includes: find returns success", el_find.success?)
assert("includes :tags preloaded on find", el_find.value.association(:tags).loaded?)

# Without includes — not preloaded
plain_result = PostService.call(action: :find, params: { id: p_el.id }, context: ctx)
assert("without includes: tags NOT preloaded", !plain_result.value.association(:tags).loaded?)

# ── 5. NESTED WRITES (has_many) ───────────────────────────────────────────────
puts "\n=== 5. Nested Writes ==="

rn = PostWithCommentsService.call(
  action: :create,
  params: {
    attributes: { title: "Post+Comments", status: "draft" },
    comments: [
      { attributes: { author: "Alice", body: "Great!" } },
      { attributes: { author: "Bob",   body: "Nice!" } }
    ]
  },
  context: ctx
)
assert("nested create post+comments", rn.success?)
assert("nested create: 2 comments persisted", rn.value.comments.count == 2)

# invalid nested child rolls back entire transaction
rn_bad = PostWithCommentsService.call(
  action: :create,
  params: {
    attributes: { title: "With Bad Comment" },
    comments: [{ attributes: { author: "", body: "" } }]
  },
  context: ctx
)
assert("invalid nested child rolls back post", rn_bad.failure?)
assert("post not persisted on nested failure", !Post.exists?(title: "With Bad Comment"))

# update: add new child
rnu = PostWithCommentsService.call(
  action: :update,
  params: {
    id: rn.value.id,
    attributes: { title: "Post+Comments Updated" },
    comments: [{ attributes: { author: "Carol", body: "Hello!" } }]
  },
  context: ctx
)
assert("nested update post title", rnu.success? && rnu.value.title == "Post+Comments Updated")

# update: _destroy flag removes an existing child
comment_to_destroy = rn.value.comments.first
rnd_flag = PostWithCommentsService.call(
  action: :update,
  params: {
    id: rn.value.id,
    attributes: { title: "Post+Comments Updated" },
    comments: [{ id: comment_to_destroy.id, _destroy: true }]
  },
  context: ctx
)
assert("_destroy flag removes nested child", rnd_flag.success?)
assert("child deleted via _destroy", !Comment.exists?(comment_to_destroy.id))

# cascade destroy (dependent: :destroy)
post_to_destroy = rn.value.id
rnd = PostWithCommentsService.call(action: :destroy, params: { id: post_to_destroy }, context: ctx)
assert("nested cascade destroy", rnd.success?)
assert("cascade: comments gone", Comment.where(post_id: post_to_destroy).count == 0)

# ── 6. DEPENDENT: :nullify ────────────────────────────────────────────────────
puts "\n=== 6. Dependent: :nullify ==="

p_null = Post.create!(title: "Nullify Post", status: "draft")
c_null = Comment.create!(post_id: p_null.id, author: "Dan", body: "Stays!")
rn2 = PostNullifyService.call(action: :destroy, params: { id: p_null.id }, context: ctx)
assert("nullify: parent destroyed", rn2.success? && !Post.exists?(p_null.id))
assert("nullify: child still exists with null FK", Comment.exists?(c_null.id) && Comment.find(c_null.id).post_id.nil?)

# ── 7. DEPENDENT: :restrict ───────────────────────────────────────────────────
puts "\n=== 7. Dependent: :restrict ==="

p_restr = Post.create!(title: "Restrict Post", status: "draft")
Comment.create!(post_id: p_restr.id, author: "Eve", body: "Block me!")
rr = PostRestrictService.call(action: :destroy, params: { id: p_restr.id }, context: ctx)
assert("restrict: fails when children exist", rr.failure? && rr.error.code == "validation_error")
assert("restrict: parent not destroyed", Post.exists?(p_restr.id))

p_empty = Post.create!(title: "Restrict Empty", status: "draft")
rr2 = PostRestrictService.call(action: :destroy, params: { id: p_empty.id }, context: ctx)
assert("restrict: succeeds when no children", rr2.success?)

# ── 8. BULK ───────────────────────────────────────────────────────────────────
puts "\n=== 8. Bulk ==="

rb1 = BulkPostService.call(
  action: :bulk_create,
  params: { transaction_mode: :best_effort, items: [{ title: "Bulk A", status: "draft" }, { title: "Bulk B", status: "published" }] },
  context: ctx
)
assert("bulk_create best_effort → success", rb1.success?)
assert("bulk_create: 2 created", rb1.value[:summary][:success_count] == 2)

rb2 = BulkPostService.call(
  action: :bulk_create,
  params: { transaction_mode: :best_effort, items: [{ title: "Good" }, { title: "" }] },
  context: ctx
)
assert("bulk_create partial failure (best_effort): 1 succeed, 1 fail", rb2.success? && rb2.value[:summary][:failure_count] == 1)
assert("bulk_create best_effort: good record persisted", Post.exists?(title: "Good"))

rb3 = BulkPostService.call(
  action: :bulk_create,
  params: { transaction_mode: :all_or_nothing, items: [{ title: "Would Succeed" }, { title: "" }] },
  context: ctx
)
assert("bulk_create all_or_nothing rolls back on any failure", rb3.success? && !Post.exists?(title: "Would Succeed"))

bulk_ids = rb1.value[:items].select { |i| i[:success] }.map { |i| i[:value].id }

rb4 = BulkPostService.call(
  action: :bulk_update,
  params: { transaction_mode: :best_effort, items: [{ id: bulk_ids[0], attributes: { title: "Bulk A Updated" } }] },
  context: ctx
)
assert("bulk_update → success, title changed", rb4.success? && rb4.value[:summary][:success_count] == 1)

rb5 = BulkPostService.call(
  action: :bulk_destroy,
  params: { transaction_mode: :best_effort, items: bulk_ids.map { |id| { id: id } } },
  context: ctx
)
assert("bulk_destroy → success", rb5.success?)
assert("bulk_destroy → records gone", bulk_ids.none? { |id| Post.exists?(id) })

# bulk_create with nested has_many
bulk_nested_svc = Class.new(Railsmith::BaseService) do
  model Post
  has_many :comments, service: CommentService
end
rb6 = bulk_nested_svc.call(
  action: :bulk_create,
  params: {
    transaction_mode: :best_effort,
    items: [
      { attributes: { title: "Bulk+Nested A", status: "draft" }, comments: [{ attributes: { author: "X", body: "Y" } }] },
      { attributes: { title: "Bulk+Nested B", status: "draft" }, comments: [] }
    ]
  },
  context: ctx
)
assert("bulk_create with nested has_many", rb6.success? && rb6.value[:summary][:success_count] == 2)
assert("bulk_create nested: comment persisted with FK", Comment.exists?(author: "X"))

# ── 9. CROSS-DOMAIN GUARD ─────────────────────────────────────────────────────
puts "\n=== 9. Cross-Domain Guard ==="

# allowlisted: blog context calling billing service
warnings_allowed = []
sub1 = ActiveSupport::Notifications.subscribe("cross_domain.warning.railsmith") { |*a| warnings_allowed << a }
Billing::PostReportService.call(action: :report, params: { id: form_post.id }, context: { current_domain: :blog })
assert("allowlisted (blog→billing) emits no warning", warnings_allowed.empty?)
ActiveSupport::Notifications.unsubscribe(sub1)

# not allowlisted: warning fires
original_allowlist = Railsmith.configuration.cross_domain_allowlist
Railsmith.configuration.cross_domain_allowlist = []
warnings_blocked = []
sub2 = ActiveSupport::Notifications.subscribe("cross_domain.warning.railsmith") { |*a| warnings_blocked << a }
Billing::PostReportService.call(action: :report, params: { id: form_post.id }, context: { current_domain: :blog })
assert("non-allowlisted crossing emits warning", warnings_blocked.any?)
ActiveSupport::Notifications.unsubscribe(sub2)

# strict_mode: on_cross_domain_violation callback fires
callback_fired = false
Railsmith.configuration.strict_mode = true
Railsmith.configuration.on_cross_domain_violation = ->(_payload) { callback_fired = true }
Billing::PostReportService.call(action: :report, params: { id: form_post.id }, context: { current_domain: :blog })
assert("strict_mode: on_cross_domain_violation callback fires", callback_fired)
Railsmith.configuration.strict_mode = false
Railsmith.configuration.on_cross_domain_violation = nil
Railsmith.configuration.cross_domain_allowlist = original_allowlist

# ── 10. call! ─────────────────────────────────────────────────────────────────
puts "\n=== 10. call! ==="

begin
  PostService.call!(action: :find, params: { id: 99_999 }, context: ctx)
  assert("call! raises on failure", false)
rescue Railsmith::Failure => e
  assert("call! raises Railsmith::Failure", true)
  assert("Failure result carries not_found code", e.result.error.code == "not_found")
  assert("Failure result responds to #to_h", e.result.to_h.is_a?(Hash))
end

r_ok = PostService.call!(action: :create, params: { attributes: { title: "Bang!" } }, context: ctx)
assert("call! returns result on success", r_ok.success? && r_ok.value.title == "Bang!")

# ── 11. ControllerHelpers status map ──────────────────────────────────────────
puts "\n=== 11. ControllerHelpers ==="

map = Railsmith::ControllerHelpers::ERROR_STATUS_MAP
assert("validation_error → :unprocessable_entity", map["validation_error"] == :unprocessable_entity)
assert("not_found → :not_found",                   map["not_found"] == :not_found)
assert("conflict → :conflict",                     map["conflict"] == :conflict)
assert("unauthorized → :unauthorized",             map["unauthorized"] == :unauthorized)
assert("unexpected → :internal_server_error",      map["unexpected"] == :internal_server_error)

# ── 12. Custom coercion registration ──────────────────────────────────────────
puts "\n=== 12. Custom coercion ==="

money_coercer = Railsmith.configuration.custom_coercions[:money]
assert(":money coercion registered", !money_coercer.nil?)
assert(":money 9.99 → 999 cents", money_coercer.call("9.99") == 999)
assert(":money 0.01 → 1 cent", money_coercer.call("0.01") == 1)

# ── 13. Result object ─────────────────────────────────────────────────────────
puts "\n=== 13. Result object ==="

rs = Railsmith::Result.success(value: { data: 1 })
assert("Result.success → success?", rs.success?)
assert("Result.success → not failure?", !rs.failure?)
assert("Result.success value", rs.value == { data: 1 })

rf = Railsmith::Result.failure(error: Railsmith::Errors.not_found(message: "Gone"))
assert("Result.failure → failure?", rf.failure?)
assert("Result.failure code", rf.code == "not_found")
assert("Result.failure to_h has :error key", rf.to_h.key?(:error))

# ── 14. validate helper ───────────────────────────────────────────────────────
puts "\n=== 14. validate helper ==="

svc_instance = Railsmith::BaseService.new(params: { email: "a@b.com" }, context: {})
rv1 = svc_instance.validate(svc_instance.params, required_keys: [:email])
assert("validate: success when keys present", rv1.success?)

rv2 = svc_instance.validate(svc_instance.params, required_keys: [:email, :name])
assert("validate: failure when key missing", rv2.failure? && rv2.error.code == "validation_error")

# ── 15. arch_check CLI ────────────────────────────────────────────────────────
puts "\n=== 15. arch_check CLI ==="

# Clean controllers → exit 0
status_clean = Railsmith::ArchChecks::Cli.run(
  env: { "RAILSMITH_PATHS" => "app/controllers/api", "RAILSMITH_FAIL_ON_ARCH_VIOLATIONS" => "false" },
  output: StringIO.new
)
assert("arch_check: clean API controllers → 0", status_clean == 0)

# Dirty controller (posts_controller.rb) → violations found, but warn-only → still 0
status_warn = Railsmith::ArchChecks::Cli.run(
  env: { "RAILSMITH_PATHS" => "app/controllers", "RAILSMITH_FAIL_ON_ARCH_VIOLATIONS" => "false" },
  output: StringIO.new
)
assert("arch_check warn-only → 0 even with violations", status_warn == 0)

# fail_on=true with violations → exit 1
status_fail = Railsmith::ArchChecks::Cli.run(
  env: { "RAILSMITH_PATHS" => "app/controllers", "RAILSMITH_FAIL_ON_ARCH_VIOLATIONS" => "true" },
  output: StringIO.new
)
assert("arch_check fail_on=true with violations → 1", status_fail == 1)

# JSON format output
json_out = StringIO.new
Railsmith::ArchChecks::Cli.run(
  env: { "RAILSMITH_PATHS" => "app/controllers", "RAILSMITH_FORMAT" => "json" },
  output: json_out
)
parsed = JSON.parse(json_out.string) rescue nil
assert("arch_check JSON format is valid JSON", !parsed.nil?)
assert("arch_check JSON has violations key", parsed.is_a?(Hash) && parsed.key?("violations"))

# MissingServiceUsage detected on posts_controller
violations_out = StringIO.new
Railsmith::ArchChecks::Cli.run(
  env: { "RAILSMITH_PATHS" => "app/controllers", "RAILSMITH_FORMAT" => "json" },
  output: violations_out
)
v_data = JSON.parse(violations_out.string)
rules = v_data["violations"].map { |v| v["rule"] }.uniq
assert("arch_check detects direct_model_access", rules.include?("direct_model_access"))
assert("arch_check detects missing_service_usage", rules.include?("missing_service_usage"))

# ── 16. NESTED WRITES (has_one) ───────────────────────────────────────────────
puts "\n=== 16. Nested Writes (has_one) ==="

# create: post + has_one post_meta in one transaction
rh1 = PostWithMetaService.call(
  action: :create,
  params: {
    attributes: { title: "Post+Meta", status: "draft" },
    post_meta: { attributes: { summary: "Initial summary" } }
  },
  context: ctx
)
assert("has_one create: post+meta success", rh1.success?)
assert("has_one create: meta persisted with FK", PostMeta.exists?(post_id: rh1.value.id, summary: "Initial summary"))

# update: update the has_one record
rh2 = PostWithMetaService.call(
  action: :update,
  params: {
    id: rh1.value.id,
    attributes: { title: "Post+Meta Updated" },
    post_meta: { id: rh1.value.post_meta.id, attributes: { summary: "Updated summary" } }
  },
  context: ctx
)
assert("has_one update: post title updated", rh2.success? && rh2.value.title == "Post+Meta Updated")
assert("has_one update: meta summary updated", rh1.value.post_meta.reload.summary == "Updated summary")

# update: _destroy flag removes the has_one record
meta_to_destroy = rh1.value.post_meta
rh3 = PostWithMetaService.call(
  action: :update,
  params: {
    id: rh1.value.id,
    attributes: { title: "Post+Meta Updated" },
    post_meta: { id: meta_to_destroy.id, _destroy: true }
  },
  context: ctx
)
assert("has_one _destroy removes nested record", rh3.success?)
assert("has_one _destroy: meta gone", !PostMeta.exists?(meta_to_destroy.id))

# create without meta — meta key absent → no nested write
rh4 = PostWithMetaService.call(
  action: :create,
  params: { attributes: { title: "No Meta", status: "draft" } },
  context: ctx
)
assert("has_one: create without meta key → success, no meta row", rh4.success? && PostMeta.find_by(post_id: rh4.value.id).nil?)

# cascade destroy: destroying the post also destroys the meta (dependent: :destroy)
post_with_meta = Post.create!(title: "Cascade Meta", status: "draft")
PostMeta.create!(post_id: post_with_meta.id, summary: "Will be destroyed")
rh5 = PostWithMetaService.call(action: :destroy, params: { id: post_with_meta.id }, context: ctx)
assert("has_one cascade destroy: post destroyed", rh5.success? && !Post.exists?(post_with_meta.id))
assert("has_one cascade destroy: meta gone", !PostMeta.exists?(post_id: post_with_meta.id))

# invalid has_one rolls back parent
rh6 = PostWithMetaService.call(
  action: :create,
  params: {
    attributes: { title: "Rollback Meta", status: "draft" },
    post_meta: { attributes: { summary: "" } }  # summary is required
  },
  context: ctx
)
assert("has_one invalid child rolls back post", rh6.failure?)
assert("has_one rollback: post not persisted", !Post.exists?(title: "Rollback Meta"))

# ── 17. NESTED WRITES (belongs_to) ────────────────────────────────────────────
puts "\n=== 17. Nested Writes (belongs_to) ==="

# PostMeta belongs_to :post (optional: true) — use an inline service
meta_with_post_svc = Class.new(Railsmith::BaseService) do
  model PostMeta
  belongs_to :post, service: PostService, optional: true
end

# create: meta + new post in one transaction
rb_1 = meta_with_post_svc.call(
  action: :create,
  params: {
    attributes: { summary: "BT summary" },
    post: { attributes: { title: "BT Post", status: "draft" } }
  },
  context: ctx
)
assert("belongs_to create: meta+post success", rb_1.success?)
assert("belongs_to create: post FK set on meta", rb_1.value.post_id.present?)
assert("belongs_to create: post record persisted", Post.exists?(title: "BT Post"))

# update: update the belongs_to parent
bt_post = Post.find(rb_1.value.post_id)
rb_2 = meta_with_post_svc.call(
  action: :update,
  params: {
    id: rb_1.value.id,
    attributes: { summary: "BT summary" },
    post: { id: bt_post.id, attributes: { title: "BT Post Updated", status: "published" } }
  },
  context: ctx
)
assert("belongs_to update: post title updated", rb_2.success? && bt_post.reload.title == "BT Post Updated")

# destroy: _destroy flag removes the belongs_to parent and nullifies FK on meta
rb_3 = meta_with_post_svc.call(
  action: :update,
  params: {
    id: rb_1.value.id,
    attributes: { summary: "BT summary" },
    post: { id: bt_post.id, _destroy: true }
  },
  context: ctx
)
assert("belongs_to _destroy: post destroyed", rb_3.success? && !Post.exists?(bt_post.id))
assert("belongs_to _destroy: FK nullified on meta", rb_1.value.reload.post_id.nil?)

# ══════════════════════════════════════════════════════════════════════════════
# ASYNC NESTED WRITES — all job backends
# ══════════════════════════════════════════════════════════════════════════════

# Helper: save and restore async config around each section
original_async_job_class = Railsmith.configuration.async_job_class
original_async_enqueuer  = Railsmith.configuration.async_enqueuer

def restore_async_config!(job_class, enqueuer)
  Railsmith.configuration.async_job_class = job_class
  Railsmith.configuration.async_enqueuer  = enqueuer
end

# ── 18. ASYNC: ActiveJob inline-adapter smoke test ───────────────────────────
puts "\n=== 18. Async Nested Writes (ActiveJob :inline smoke test) ==="

# Uses the ActiveJob :inline adapter — jobs run synchronously in the same
# process. This proves the enqueue path wires up against ActiveJob at all;
# it does NOT prove the async timing contract (parent-commits-before-child).
# That contract is exercised in section 31 with the :test adapter.
previous_aj_adapter = ActiveJob::Base.queue_adapter
ActiveJob::Base.queue_adapter = :inline
Railsmith.configuration.async_job_class = Railsmith::AsyncNestedWriteJob
Railsmith.configuration.async_enqueuer  = nil

# create: parent commits, then job creates comments inline
ra1 = PostWithAsyncCommentsService.call(
  action: :create,
  params: {
    attributes: { title: "Async+Comments AJ", status: "draft" },
    comments: [
      { attributes: { author: "Alice", body: "Async comment 1" } },
      { attributes: { author: "Bob", body: "Async comment 2" } }
    ]
  },
  context: ctx
)
assert("AJ async create: parent success", ra1.success?)
assert("AJ async create: parent persisted", Post.exists?(title: "Async+Comments AJ"))
# With :inline adapter, the job runs synchronously so comments should exist
assert("AJ async create: comments persisted (inline adapter)", ra1.value.comments.reload.count == 2)

# meta flags the write as async
async_meta = ra1.meta&.dig(:nested, :comments)
assert("AJ async create: meta has async: true", async_meta && async_meta[:async] == true)
assert("AJ async create: meta has association name", async_meta && async_meta[:association] == :comments)
assert("AJ async create: meta has job_id", async_meta && !async_meta[:job_id].nil?)

# update: enqueue async nested write with mode :update
ra2 = PostWithAsyncCommentsService.call(
  action: :update,
  params: {
    id: ra1.value.id,
    attributes: { title: "Async+Comments AJ Updated" },
    comments: [{ attributes: { author: "Carol", body: "New async comment" } }]
  },
  context: ctx
)
assert("AJ async update: parent updated", ra2.success? && ra2.value.title == "Async+Comments AJ Updated")
assert("AJ async update: new comment created by job", Comment.exists?(author: "Carol", body: "New async comment"))

# has_one async: create post + async meta
ra3 = PostWithAsyncMetaService.call(
  action: :create,
  params: {
    attributes: { title: "Async+Meta AJ", status: "draft" },
    post_meta: { attributes: { summary: "Async summary" } }
  },
  context: ctx
)
assert("AJ async has_one create: parent success", ra3.success?)
assert("AJ async has_one create: meta persisted (inline adapter)", PostMeta.exists?(post_id: ra3.value.id, summary: "Async summary"))

# update: async has_one update
meta_record = PostMeta.find_by(post_id: ra3.value.id)
ra4 = PostWithAsyncMetaService.call(
  action: :update,
  params: {
    id: ra3.value.id,
    attributes: { title: "Async+Meta AJ Updated" },
    post_meta: { id: meta_record.id, attributes: { summary: "Updated async summary" } }
  },
  context: ctx
)
assert("AJ async has_one update: parent updated", ra4.success?)
assert("AJ async has_one update: meta updated by job", meta_record.reload.summary == "Updated async summary")

ActiveJob::Base.queue_adapter = previous_aj_adapter

# ── 19. ASYNC: Instrumentation events ────────────────────────────────────────
puts "\n=== 19. Async Instrumentation ==="

ActiveJob::Base.queue_adapter = :inline
Railsmith.configuration.async_job_class = Railsmith::AsyncNestedWriteJob
Railsmith.configuration.async_enqueuer  = nil

# nested_write.enqueued.railsmith event fires on enqueue — and must carry a
# payload that identifies the association, mode, parent, and job handle.
enqueued_events = []
sub_enqueue = ActiveSupport::Notifications.subscribe("nested_write.enqueued.railsmith") { |*args| enqueued_events << args }

ri1 = PostWithAsyncCommentsService.call(
  action: :create,
  params: {
    attributes: { title: "Instr Post", status: "draft" },
    comments: [{ attributes: { author: "Zed", body: "Instrumented!" } }]
  },
  context: ctx
)
assert("instrumentation: enqueued event fires", enqueued_events.any?)

# Inspect the payload (4th element of the AS::Notifications args array).
# We verify the event carries enough info to correlate with the meta returned
# to the caller — specifically the job_id — rather than asserting on every
# possible key the gem might include.
event_payload = enqueued_events.last && enqueued_events.last[4]
assert("instrumentation: payload is a Hash", event_payload.is_a?(Hash))

# Flexible fetch: accept either symbol or string keys.
fetch_payload_key = ->(key) {
  next nil unless event_payload.is_a?(Hash)
  event_payload[key] || event_payload[key.to_s] || event_payload[key.to_sym]
}

payload_job_id   = fetch_payload_key.call(:job_id)
payload_assoc    = fetch_payload_key.call(:association)
meta_job_id      = ri1.meta.dig(:nested, :comments, :job_id)

assert(
  "instrumentation: payload job_id present and matches result.meta job_id",
  !payload_job_id.nil? && payload_job_id == meta_job_id
)
assert(
  "instrumentation: payload association names :comments (symbol or string)",
  payload_assoc.to_s == "comments"
)

ActiveSupport::Notifications.unsubscribe(sub_enqueue)

ActiveJob::Base.queue_adapter = previous_aj_adapter

# ── 20. ASYNC: Context propagation ──────────────────────────────────────────
puts "\n=== 20. Async Context Propagation ==="

# Use :test so we can intercept the enqueued payload AND run it manually.
# That lets us prove two distinct things:
#  (a) the context the caller supplied was serialized into the job payload
#  (b) when the job runs, that context is in scope for the nested service
ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.queue_adapter.enqueued_jobs.clear
Railsmith.configuration.async_job_class = Railsmith::AsyncNestedWriteJob
Railsmith.configuration.async_enqueuer  = nil

rich_ctx = { current_domain: :blog, request_id: "req-async-123", actor_id: 42, tenant_id: "t-9" }
rc1 = PostWithAsyncCommentsService.call(
  action: :create,
  params: {
    attributes: { title: "Context Prop Post", status: "draft" },
    comments: [{ attributes: { author: "Ctx", body: "Context test" } }]
  },
  context: rich_ctx
)
assert("context propagation: parent created", rc1.success?)
assert("context propagation: comments NOT yet persisted (job deferred)", !Comment.exists?(author: "Ctx", body: "Context test"))

# (a) Serialized payload must carry the context verbatim.
cprop_job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
cprop_args = cprop_job[:args].first
serialized_ctx = cprop_args["context"] || cprop_args[:context] || {}
# The payload uses string or symbol keys depending on serialization — normalize.
ctx_fetch = ->(key) { serialized_ctx[key] || serialized_ctx[key.to_s] || serialized_ctx[key.to_sym] }
assert("context propagation: request_id serialized into payload", ctx_fetch.call(:request_id) == "req-async-123")
assert("context propagation: actor_id serialized into payload",   ctx_fetch.call(:actor_id)   == 42)
assert("context propagation: tenant_id serialized into payload",  ctx_fetch.call(:tenant_id)  == "t-9")

# (b) When the job runs, the nested service should rebuild context from the
# serialized payload. Probe this by wrapping Railsmith::Context.build to
# record the hash it receives while the job is executing — this proves the
# worker actually feeds the payload through the Context builder instead of
# silently dropping it.
observed_builds = []
Railsmith::Context.singleton_class.class_eval do
  alias_method :__orig_build_for_probe, :build unless method_defined?(:__orig_build_for_probe)
  define_method(:build) do |attrs = {}|
    observed_builds << attrs
    __orig_build_for_probe(attrs)
  end
end

Railsmith::AsyncNestedWriteJob.perform_now(**cprop_args.transform_keys(&:to_sym))

Railsmith::Context.singleton_class.class_eval do
  alias_method :build, :__orig_build_for_probe
  remove_method :__orig_build_for_probe
end

# Find at least one build call that matches the rich_ctx identifiers.
matching_build = observed_builds.find do |h|
  h.is_a?(Hash) && (
    (h[:request_id] || h["request_id"]) == "req-async-123" &&
    ((h[:actor_id]   || h["actor_id"])   == 42)
  )
end

assert("context propagation: job invoked Railsmith::Context.build", observed_builds.any?)
assert("context propagation: request_id+actor_id reached Context.build inside job", !matching_build.nil?)
assert("context propagation: comment actually persisted by job", Comment.exists?(author: "Ctx", body: "Context test"))

ActiveJob::Base.queue_adapter = previous_aj_adapter

# ── 21. ASYNC: AsyncNotConfiguredError when no job class set ─────────────────
puts "\n=== 21. AsyncNotConfiguredError ==="

Railsmith.configuration.async_job_class = nil
Railsmith.configuration.async_enqueuer  = nil

begin
  PostWithAsyncCommentsService.call(
    action: :create,
    params: {
      attributes: { title: "Should Fail", status: "draft" },
      comments: [{ attributes: { author: "X", body: "Y" } }]
    },
    context: ctx
  )
  assert("AsyncNotConfiguredError: should raise", false)
rescue Railsmith::AsyncNotConfiguredError => e
  assert("AsyncNotConfiguredError: raised correctly", e.message.include?("async_job_class"))
rescue => e
  assert("AsyncNotConfiguredError: unexpected error class #{e.class}", false)
end
# Parent should NOT be persisted — the error fires during create before commit
assert("AsyncNotConfiguredError: parent not persisted", !Post.exists?(title: "Should Fail"))

# ── 22. ASYNC: async: true incompatible with dependent: :destroy ─────────────
puts "\n=== 22. Async + dependent: incompatibility ==="

# async: true + dependent: :destroy should raise ArgumentError at definition time
begin
  Class.new(Railsmith::BaseService) do
    model Post
    has_many :comments, service: CommentService, async: true, dependent: :destroy
  end
  assert("async+dependent:destroy raises ArgumentError", false)
rescue ArgumentError => e
  assert("async+dependent:destroy raises ArgumentError", e.message.include?("async: true is not compatible"))
end

# async: true + dependent: :nullify
begin
  Class.new(Railsmith::BaseService) do
    model Post
    has_many :comments, service: CommentService, async: true, dependent: :nullify
  end
  assert("async+dependent:nullify raises ArgumentError", false)
rescue ArgumentError => e
  assert("async+dependent:nullify raises ArgumentError", e.message.include?("async: true is not compatible"))
end

# async: true + dependent: :restrict
begin
  Class.new(Railsmith::BaseService) do
    model Post
    has_many :comments, service: CommentService, async: true, dependent: :restrict
  end
  assert("async+dependent:restrict raises ArgumentError", false)
rescue ArgumentError => e
  assert("async+dependent:restrict raises ArgumentError", e.message.include?("async: true is not compatible"))
end

# async: true + dependent: :ignore (default) — should be fine
begin
  svc = Class.new(Railsmith::BaseService) do
    model Post
    has_many :comments, service: CommentService, async: true, dependent: :ignore
  end
  assert("async+dependent:ignore is allowed", true)
rescue => e
  assert("async+dependent:ignore is allowed (got #{e.class}: #{e.message})", false)
end

# ── 23. ASYNC: Native Sidekiq worker (perform_async path) ───────────────────
puts "\n=== 23. Async via Sidekiq Native Worker ==="

# Build a fake Sidekiq-like class that records calls (no real Sidekiq needed)
fake_sidekiq_worker = Class.new do
  class << self
    attr_accessor :jobs

    def perform_async(payload)
      @jobs ||= []
      jid = "jid-#{@jobs.size + 1}"
      @jobs << { payload: payload, jid: jid }
      jid
    end

    def reset!
      @jobs = []
    end
  end
end
fake_sidekiq_worker.reset!

Railsmith.configuration.async_job_class = fake_sidekiq_worker
Railsmith.configuration.async_enqueuer  = nil

rs1 = PostWithAsyncCommentsService.call(
  action: :create,
  params: {
    attributes: { title: "Sidekiq Async Post", status: "draft" },
    comments: [
      { attributes: { author: "Sid", body: "Sidekiq comment" } }
    ]
  },
  context: ctx
)
assert("Sidekiq: parent created successfully", rs1.success?)
assert("Sidekiq: parent persisted", Post.exists?(title: "Sidekiq Async Post"))
# Comments NOT written inline (enqueued to Sidekiq)
assert("Sidekiq: comments NOT written inline", rs1.value.comments.reload.count == 0)
assert("Sidekiq: job enqueued", fake_sidekiq_worker.jobs.size == 1)
assert("Sidekiq: payload has correct association", fake_sidekiq_worker.jobs.first[:payload][:association] == "comments")
assert("Sidekiq: payload has correct mode", fake_sidekiq_worker.jobs.first[:payload][:mode] == "create")
assert("Sidekiq: meta has job_id (jid)", rs1.meta.dig(:nested, :comments, :job_id) == "jid-1")

# ── 24. ASYNC: Kicks-style publisher (publish path) ─────────────────────────
puts "\n=== 24. Async via Kicks Publisher ==="

# Build a fake Kicks-like class
fake_kicks_publisher = Class.new do
  class << self
    attr_accessor :messages

    def publish(payload)
      @messages ||= []
      token = "pub-#{@messages.size + 1}"
      @messages << { payload: payload, token: token }
      token
    end

    def reset!
      @messages = []
    end
  end
end
fake_kicks_publisher.reset!

Railsmith.configuration.async_job_class = fake_kicks_publisher
Railsmith.configuration.async_enqueuer  = nil

rk1 = PostWithAsyncCommentsService.call(
  action: :create,
  params: {
    attributes: { title: "Kicks Async Post", status: "draft" },
    comments: [
      { attributes: { author: "Kick", body: "Kicks comment" } }
    ]
  },
  context: ctx
)
assert("Kicks: parent created successfully", rk1.success?)
assert("Kicks: parent persisted", Post.exists?(title: "Kicks Async Post"))
assert("Kicks: comments NOT written inline", rk1.value.comments.reload.count == 0)
assert("Kicks: message published", fake_kicks_publisher.messages.size == 1)
assert("Kicks: payload has correct association", fake_kicks_publisher.messages.first[:payload][:association] == "comments")
assert("Kicks: meta has job_id (token)", rk1.meta.dig(:nested, :comments, :job_id) == "pub-1")

# ── 25. ASYNC: Custom enqueuer (config.async_enqueuer proc) ─────────────────
puts "\n=== 25. Async via Custom Enqueuer ==="

custom_queue = []
custom_job_class = Class.new  # bare class — no perform_later or perform_async

Railsmith.configuration.async_job_class = custom_job_class
Railsmith.configuration.async_enqueuer  = ->(job_class, payload) {
  custom_queue << { job_class: job_class, payload: payload }
  "custom-id-#{custom_queue.size}"
}

rce1 = PostWithAsyncCommentsService.call(
  action: :create,
  params: {
    attributes: { title: "Custom Enqueuer Post", status: "draft" },
    comments: [
      { attributes: { author: "Custom", body: "Custom enqueuer comment" } }
    ]
  },
  context: ctx
)
assert("Custom enqueuer: parent created", rce1.success?)
assert("Custom enqueuer: parent persisted", Post.exists?(title: "Custom Enqueuer Post"))
assert("Custom enqueuer: comments NOT written inline", rce1.value.comments.reload.count == 0)
assert("Custom enqueuer: job enqueued via custom proc", custom_queue.size == 1)
assert("Custom enqueuer: payload has correct data", custom_queue.first[:payload][:association] == "comments")
assert("Custom enqueuer: job_class passed through", custom_queue.first[:job_class] == custom_job_class)
assert("Custom enqueuer: meta has custom job_id", rce1.meta.dig(:nested, :comments, :job_id) == "custom-id-1")

# ── 26. ASYNC: publish_async path (Sneakers-style) ──────────────────────────
puts "\n=== 26. Async via publish_async (Sneakers-style) ==="

fake_sneakers = Class.new do
  class << self
    attr_accessor :messages

    def publish_async(payload)
      @messages ||= []
      token = "sneaker-#{@messages.size + 1}"
      @messages << { payload: payload, token: token }
      token
    end

    def reset!
      @messages = []
    end
  end
end
fake_sneakers.reset!

Railsmith.configuration.async_job_class = fake_sneakers
Railsmith.configuration.async_enqueuer  = nil

rsn1 = PostWithAsyncCommentsService.call(
  action: :create,
  params: {
    attributes: { title: "Sneakers Async Post", status: "draft" },
    comments: [
      { attributes: { author: "Sneak", body: "Sneakers comment" } }
    ]
  },
  context: ctx
)
assert("Sneakers: parent created", rsn1.success?)
assert("Sneakers: message published via publish_async", fake_sneakers.messages.size == 1)
assert("Sneakers: meta has job_id (token)", rsn1.meta.dig(:nested, :comments, :job_id) == "sneaker-1")

# ── 27. ASYNC: perform_nested_write_for_job (job re-entry) ──────────────────
puts "\n=== 27. perform_nested_write_for_job (Job Re-entry) ==="

# This simulates what the job does: directly calling the service's
# perform_nested_write_for_job method to write nested records inline.

Railsmith.configuration.async_job_class = Railsmith::AsyncNestedWriteJob
Railsmith.configuration.async_enqueuer  = nil

# Create a parent post first (without nested records)
p_reentry = Post.create!(title: "Reentry Parent", status: "draft")

# Simulate what the job does: call perform_nested_write_for_job
svc_instance = PostWithAsyncCommentsService.new(params: {}, context: Railsmith::Context.build(ctx))
reentry_result = svc_instance.send(
  :perform_nested_write_for_job,
  :comments,
  p_reentry,
  [{ attributes: { author: "JobRunner", body: "Written by job" } }],
  :create
)
assert("job re-entry: nested write succeeds", reentry_result.success?)
assert("job re-entry: comment persisted with FK", Comment.exists?(post_id: p_reentry.id, author: "JobRunner"))

# has_one re-entry
svc_instance2 = PostWithAsyncMetaService.new(params: {}, context: Railsmith::Context.build(ctx))
reentry_result2 = svc_instance2.send(
  :perform_nested_write_for_job,
  :post_meta,
  p_reentry,
  { attributes: { summary: "Reentry meta" } },
  :create
)
assert("job re-entry has_one: nested write succeeds", reentry_result2.success?)
assert("job re-entry has_one: meta persisted", PostMeta.exists?(post_id: p_reentry.id, summary: "Reentry meta"))

# Unknown association raises ArgumentError
begin
  svc_instance.send(:perform_nested_write_for_job, :nonexistent, p_reentry, [], :create)
  assert("job re-entry: unknown association raises", false)
rescue ArgumentError => e
  assert("job re-entry: unknown association raises ArgumentError", e.message.include?("unknown association"))
end

# ── 28. ASYNC: No nested key → no enqueue ───────────────────────────────────
puts "\n=== 28. Async: No nested key = no enqueue ==="

fake_sidekiq_worker.reset!
Railsmith.configuration.async_job_class = fake_sidekiq_worker
Railsmith.configuration.async_enqueuer  = nil

rnn1 = PostWithAsyncCommentsService.call(
  action: :create,
  params: {
    attributes: { title: "No Nested Key Post", status: "draft" }
    # No :comments key — should NOT enqueue anything
  },
  context: ctx
)
assert("no nested key: parent created", rnn1.success?)
assert("no nested key: no job enqueued", fake_sidekiq_worker.jobs.empty?)

# ── 29. ASYNC: Sync associations still work alongside async ─────────────────
puts "\n=== 29. Sync + Async side by side ==="

# Use :test so the timing difference between sync-in-transaction vs
# async-after-commit is actually observable. With :inline the two are
# indistinguishable — both end up written synchronously.
ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.queue_adapter.enqueued_jobs.clear
Railsmith.configuration.async_job_class = Railsmith::AsyncNestedWriteJob
Railsmith.configuration.async_enqueuer  = nil

# Build a service with both sync and async associations (must be named for async job resolution)
Object.send(:remove_const, :MixedSyncAsyncService) if Object.const_defined?(:MixedSyncAsyncService)
Object.const_set(:MixedSyncAsyncService, Class.new(Railsmith::BaseService) {
  model Post
  domain :blog
  has_one :post_meta, service: PostMetaService, dependent: :destroy  # sync
  has_many :comments, service: CommentService, async: true            # async
})

rmx1 = MixedSyncAsyncService.call(
  action: :create,
  params: {
    attributes: { title: "Mixed Sync+Async", status: "draft" },
    post_meta: { attributes: { summary: "Sync meta" } },
    comments: [{ attributes: { author: "Async", body: "Async comment" } }]
  },
  context: ctx
)
assert("mixed: parent created", rmx1.success?)
# Sync child MUST be in DB right now — it was written inside the parent transaction.
assert("mixed: sync has_one meta persisted in transaction", PostMeta.exists?(post_id: rmx1.value.id, summary: "Sync meta"))
# Async child MUST NOT be in DB yet — it was deferred to a job.
assert("mixed: async comments NOT yet persisted (deferred to job)", !Comment.exists?(post_id: rmx1.value.id, author: "Async"))
assert("mixed: exactly one job enqueued for async association", ActiveJob::Base.queue_adapter.enqueued_jobs.size == 1)

# Run the job — now the async child should appear.
mixed_job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
Railsmith::AsyncNestedWriteJob.perform_now(**mixed_job[:args].first.transform_keys(&:to_sym))
assert("mixed: async comment persisted after job runs", Comment.exists?(post_id: rmx1.value.id, author: "Async"))

# meta should have both nested entries with correct async flags
assert("mixed: sync meta in result.meta", rmx1.meta&.dig(:nested, :post_meta))
assert("mixed: sync post_meta meta does NOT flag async", rmx1.meta&.dig(:nested, :post_meta, :async) != true)
assert("mixed: async comments meta flags async: true", rmx1.meta&.dig(:nested, :comments, :async) == true)

ActiveJob::Base.queue_adapter.enqueued_jobs.clear
ActiveJob::Base.queue_adapter = previous_aj_adapter

# ── 30. ASYNC: RailsmithKicksPublisher (sample app publisher) ───────────────
puts "\n=== 30. RailsmithKicksPublisher (sample publisher with drain!) ==="

Railsmith.configuration.async_job_class = RailsmithKicksPublisher
Railsmith.configuration.async_enqueuer  = ->(job_class, payload) { job_class.publish(payload) }
RailsmithKicksPublisher.clear!

rkp1 = PostWithAsyncCommentsService.call(
  action: :create,
  params: {
    attributes: { title: "Kicks Publisher Post", status: "draft" },
    comments: [
      { attributes: { author: "KickDrain", body: "Will be drained" } }
    ]
  },
  context: ctx
)
assert("KicksPublisher: parent created", rkp1.success?)
assert("KicksPublisher: message in queue", RailsmithKicksPublisher::PUBLISHED_MESSAGES.size == 1)
assert("KicksPublisher: comment NOT yet persisted", !Comment.exists?(post_id: rkp1.value.id, author: "KickDrain"))

# Drain the queue — simulates consumer processing
RailsmithKicksPublisher.drain!
assert("KicksPublisher: queue drained", RailsmithKicksPublisher::PUBLISHED_MESSAGES.empty?)
assert("KicksPublisher: comment persisted after drain!", Comment.exists?(post_id: rkp1.value.id, author: "KickDrain"))

# Restore original config
restore_async_config!(original_async_job_class, original_async_enqueuer)

# ══════════════════════════════════════════════════════════════════════════════
# REAL ASYNC CONTRACT TESTS — proving actual async behavior
# ══════════════════════════════════════════════════════════════════════════════

# ── 31. TRUE ASYNC CONTRACT: parent commits BEFORE child runs ────────────────
puts "\n=== 31. True Async Contract (parent commits, child runs later) ==="

# Use :test adapter — captures jobs without executing them
ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.queue_adapter.enqueued_jobs.clear
ActiveJob::Base.queue_adapter.performed_jobs.clear
Railsmith.configuration.async_job_class = Railsmith::AsyncNestedWriteJob
Railsmith.configuration.async_enqueuer  = nil

rtc1 = PostWithAsyncCommentsService.call(
  action: :create,
  params: {
    attributes: { title: "True Async Post", status: "draft" },
    comments: [
      { attributes: { author: "Deferred", body: "I should not exist yet" } }
    ]
  },
  context: ctx
)

# Parent MUST be committed
assert("true async: parent committed", rtc1.success?)
assert("true async: parent in DB", Post.exists?(title: "True Async Post"))
# Child MUST NOT exist yet — this is the core async contract
assert("true async: child NOT yet persisted", !Comment.exists?(post_id: rtc1.value.id, author: "Deferred"))
# Job MUST be enqueued
assert("true async: job captured by :test adapter", ActiveJob::Base.queue_adapter.enqueued_jobs.size >= 1)

# Now manually execute the captured job to prove it works
job_data = ActiveJob::Base.queue_adapter.enqueued_jobs.last
Railsmith::AsyncNestedWriteJob.perform_now(**job_data[:args].first.transform_keys(&:to_sym))

assert("true async: child persisted AFTER job runs", Comment.exists?(post_id: rtc1.value.id, author: "Deferred"))

# Same for has_one
ActiveJob::Base.queue_adapter.enqueued_jobs.clear
rtc2 = PostWithAsyncMetaService.call(
  action: :create,
  params: {
    attributes: { title: "True Async Meta Post", status: "draft" },
    post_meta: { attributes: { summary: "Deferred meta" } }
  },
  context: ctx
)
assert("true async has_one: parent committed", rtc2.success?)
assert("true async has_one: meta NOT yet persisted", !PostMeta.exists?(post_id: rtc2.value.id))
assert("true async has_one: job enqueued", ActiveJob::Base.queue_adapter.enqueued_jobs.size >= 1)

job_data2 = ActiveJob::Base.queue_adapter.enqueued_jobs.last
Railsmith::AsyncNestedWriteJob.perform_now(**job_data2[:args].first.transform_keys(&:to_sym))
assert("true async has_one: meta persisted AFTER job runs", PostMeta.exists?(post_id: rtc2.value.id, summary: "Deferred meta"))

# ── 32. JOB FAILURE: child fails, parent stays committed ────────────────────
puts "\n=== 32. Job Failure (child fails, parent survives) ==="

ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.queue_adapter.enqueued_jobs.clear
Railsmith.configuration.async_job_class = Railsmith::AsyncNestedWriteJob
Railsmith.configuration.async_enqueuer  = nil

rjf1 = PostWithAsyncCommentsService.call(
  action: :create,
  params: {
    attributes: { title: "Survives Child Failure", status: "draft" },
    comments: [
      { attributes: { author: "", body: "" } }  # invalid — will fail validation
    ]
  },
  context: ctx
)
assert("job failure: parent committed despite bad child params", rjf1.success?)
assert("job failure: parent in DB", Post.exists?(title: "Survives Child Failure"))
assert("job failure: child NOT persisted", !Comment.exists?(post_id: rjf1.value.id))

# Execute the job — it should raise because author/body are blank. We assert
# specifically on a validation-style error (RecordInvalid / ValidationError /
# Railsmith::Error) rather than "anything non-nil", so unrelated exceptions
# (e.g. a typo in the test harness) don't accidentally pass.
job_data_fail = ActiveJob::Base.queue_adapter.enqueued_jobs.last
failed_job_error = nil
begin
  Railsmith::AsyncNestedWriteJob.perform_now(**job_data_fail[:args].first.transform_keys(&:to_sym))
rescue => e
  failed_job_error = e
end
assert("job failure: job raises on invalid child", !failed_job_error.nil?)

expected_failure_classes = [
  ActiveRecord::RecordInvalid,
  defined?(Railsmith::NestedWriteError) ? Railsmith::NestedWriteError : nil,
  defined?(Railsmith::ValidationError)  ? Railsmith::ValidationError  : nil,
  defined?(Railsmith::Error)            ? Railsmith::Error            : nil
].compact

assert(
  "job failure: error class is validation-shaped (got #{failed_job_error&.class})",
  failed_job_error && expected_failure_classes.any? { |klass| failed_job_error.is_a?(klass) }
)
assert(
  "job failure: error message mentions validation / blank / required fields",
  failed_job_error && failed_job_error.message.to_s.match?(/blank|can't be|validation|invalid/i)
)
# Parent STILL exists — this is the key contract
assert("job failure: parent STILL in DB after child job fails", Post.exists?(title: "Survives Child Failure"))
assert("job failure: invalid child NOT persisted", !Comment.exists?(post_id: rjf1.value.id))

# ── 33. FAILURE INSTRUMENTATION: async_nested_write.failed fires ─────────────
puts "\n=== 33. Failure Instrumentation ==="

ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.queue_adapter.enqueued_jobs.clear
Railsmith.configuration.async_job_class = Railsmith::AsyncNestedWriteJob
Railsmith.configuration.async_enqueuer  = nil

failed_events = []
sub_fail = ActiveSupport::Notifications.subscribe("async_nested_write.failed.railsmith") do |*args|
  failed_events << args
end

rfi1 = PostWithAsyncCommentsService.call(
  action: :create,
  params: {
    attributes: { title: "Failure Instrumentation Post", status: "draft" },
    comments: [{ attributes: { author: "", body: "" } }]  # will fail
  },
  context: ctx
)

# Execute the failing job
job_data_fi = ActiveJob::Base.queue_adapter.enqueued_jobs.last
begin
  Railsmith::AsyncNestedWriteJob.perform_now(**job_data_fi[:args].first.transform_keys(&:to_sym))
rescue
  # expected
end

assert("failure instrumentation: event fired", failed_events.any?)

# Payload must identify what failed: association, parent_id, and the error.
failure_event_payload = failed_events.last && failed_events.last[4]
assert("failure instrumentation: payload is a Hash", failure_event_payload.is_a?(Hash))

failure_fetch = ->(key) {
  next nil unless failure_event_payload.is_a?(Hash)
  failure_event_payload[key] || failure_event_payload[key.to_s] || failure_event_payload[key.to_sym]
}

assert(
  "failure instrumentation: payload names :comments association",
  failure_fetch.call(:association).to_s == "comments"
)
assert(
  "failure instrumentation: payload carries parent_id of the surviving post",
  failure_fetch.call(:parent_id) == rfi1.value.id
)

# The error field should carry either the exception or a readable message.
error_field = failure_fetch.call(:error) || failure_fetch.call(:exception) || failure_fetch.call(:error_message)
assert(
  "failure instrumentation: payload carries error info",
  !error_field.nil? &&
    (error_field.is_a?(Exception) ||
     (error_field.is_a?(String) && error_field.match?(/blank|can't be|validation|invalid/i)) ||
     (error_field.is_a?(Array) && error_field.any? { |x| x.to_s.match?(/blank|can't be|validation|invalid/i) }))
)

ActiveSupport::Notifications.unsubscribe(sub_fail)

# ── 34. PARENT DELETED BEFORE JOB RUNS ──────────────────────────────────────
puts "\n=== 34. Parent Deleted Before Job Runs ==="

ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.queue_adapter.enqueued_jobs.clear
Railsmith.configuration.async_job_class = Railsmith::AsyncNestedWriteJob
Railsmith.configuration.async_enqueuer  = nil

rpd1 = PostWithAsyncCommentsService.call(
  action: :create,
  params: {
    attributes: { title: "Will Be Deleted", status: "draft" },
    comments: [{ attributes: { author: "Orphan", body: "My parent will die" } }]
  },
  context: ctx
)
assert("parent deleted: parent initially created", rpd1.success?)
deleted_post_id = rpd1.value.id

# Delete the parent BEFORE the job runs
Post.find(deleted_post_id).destroy!
assert("parent deleted: parent gone", !Post.exists?(deleted_post_id))

# Execute the job — should raise RecordNotFound
job_data_pd = ActiveJob::Base.queue_adapter.enqueued_jobs.last
parent_deleted_error = nil
begin
  Railsmith::AsyncNestedWriteJob.perform_now(**job_data_pd[:args].first.transform_keys(&:to_sym))
rescue ActiveRecord::RecordNotFound => e
  parent_deleted_error = e
rescue => e
  parent_deleted_error = e
end
assert("parent deleted: job raises RecordNotFound", parent_deleted_error.is_a?(ActiveRecord::RecordNotFound))
assert("parent deleted: orphan comment NOT created", !Comment.exists?(author: "Orphan", body: "My parent will die"))

# ── 35. ASYNC _destroy FLAG ─────────────────────────────────────────────────
puts "\n=== 35. Async _destroy Flag ==="

ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.queue_adapter.enqueued_jobs.clear
Railsmith.configuration.async_job_class = Railsmith::AsyncNestedWriteJob
Railsmith.configuration.async_enqueuer  = nil

# First create a post with comments synchronously
p_destroy = Post.create!(title: "Async Destroy Test", status: "draft")
c_to_destroy = Comment.create!(post_id: p_destroy.id, author: "Doomed", body: "Will be destroyed async")

# Now update with _destroy flag via async service
rad1 = PostWithAsyncCommentsService.call(
  action: :update,
  params: {
    id: p_destroy.id,
    attributes: { title: "Async Destroy Test Updated" },
    comments: [{ id: c_to_destroy.id, _destroy: true }]
  },
  context: ctx
)
assert("async _destroy: update enqueued", rad1.success?)
assert("async _destroy: parent updated", rad1.value.title == "Async Destroy Test Updated")
# Comment still exists — job hasn't run yet
assert("async _destroy: comment still exists before job", Comment.exists?(c_to_destroy.id))

# Execute the job
job_data_ad = ActiveJob::Base.queue_adapter.enqueued_jobs.last
Railsmith::AsyncNestedWriteJob.perform_now(**job_data_ad[:args].first.transform_keys(&:to_sym))
assert("async _destroy: comment destroyed after job runs", !Comment.exists?(c_to_destroy.id))

# ── 36. ASYNC MIXED OPS (create + update + destroy in one payload) ──────────
puts "\n=== 36. Async Mixed Operations ==="

ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.queue_adapter.enqueued_jobs.clear
Railsmith.configuration.async_job_class = Railsmith::AsyncNestedWriteJob
Railsmith.configuration.async_enqueuer  = nil

# Setup: post with two existing comments
p_mixed = Post.create!(title: "Async Mixed Ops", status: "draft")
c_keep = Comment.create!(post_id: p_mixed.id, author: "Keeper", body: "Will be updated")
c_remove = Comment.create!(post_id: p_mixed.id, author: "Goner", body: "Will be destroyed")

# Update with mixed ops: update one, destroy one, create new
ram1 = PostWithAsyncCommentsService.call(
  action: :update,
  params: {
    id: p_mixed.id,
    attributes: { title: "Async Mixed Ops Updated" },
    comments: [
      { id: c_keep.id, attributes: { body: "Updated body" } },          # update
      { id: c_remove.id, _destroy: true },                              # destroy
      { attributes: { author: "Newcomer", body: "Freshly created" } }   # create
    ]
  },
  context: ctx
)
assert("async mixed ops: update enqueued", ram1.success?)
# Nothing changed yet — all async
assert("async mixed ops: keeper NOT yet updated", Comment.find(c_keep.id).body == "Will be updated")
assert("async mixed ops: goner still exists", Comment.exists?(c_remove.id))
assert("async mixed ops: newcomer NOT yet created", !Comment.exists?(author: "Newcomer"))

# Execute the job
job_data_am = ActiveJob::Base.queue_adapter.enqueued_jobs.last
Railsmith::AsyncNestedWriteJob.perform_now(**job_data_am[:args].first.transform_keys(&:to_sym))

assert("async mixed ops: keeper updated", Comment.find(c_keep.id).body == "Updated body")
assert("async mixed ops: goner destroyed", !Comment.exists?(c_remove.id))
assert("async mixed ops: newcomer created with FK", Comment.exists?(post_id: p_mixed.id, author: "Newcomer"))

# ── 37. ASYNC WITH BULK_CREATE ──────────────────────────────────────────────
puts "\n=== 37. Async + bulk_create ==="

ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.queue_adapter.enqueued_jobs.clear
Railsmith.configuration.async_job_class = Railsmith::AsyncNestedWriteJob
Railsmith.configuration.async_enqueuer  = nil

# Service with async comments + bulk support
Object.send(:remove_const, :BulkAsyncPostService) if Object.const_defined?(:BulkAsyncPostService)
Object.const_set(:BulkAsyncPostService, Class.new(Railsmith::BaseService) {
  model Post
  domain :blog
  has_many :comments, service: CommentService, async: true
})

rab1 = BulkAsyncPostService.call(
  action: :bulk_create,
  params: {
    transaction_mode: :best_effort,
    items: [
      {
        attributes: { title: "Bulk Async A", status: "draft" },
        comments: [{ attributes: { author: "BulkA", body: "Bulk comment A" } }]
      },
      {
        attributes: { title: "Bulk Async B", status: "draft" },
        comments: [{ attributes: { author: "BulkB", body: "Bulk comment B" } }]
      }
    ]
  },
  context: ctx
)
assert("async bulk_create: parents created", rab1.success? && rab1.value[:summary][:success_count] == 2)
assert("async bulk_create: Post A in DB", Post.exists?(title: "Bulk Async A"))
assert("async bulk_create: Post B in DB", Post.exists?(title: "Bulk Async B"))
# Comments should NOT be persisted yet
post_a = Post.find_by(title: "Bulk Async A")
post_b = Post.find_by(title: "Bulk Async B")
assert("async bulk_create: comment A NOT yet persisted", !Comment.exists?(post_id: post_a.id, author: "BulkA"))
assert("async bulk_create: comment B NOT yet persisted", !Comment.exists?(post_id: post_b.id, author: "BulkB"))
# Jobs should be enqueued (one per parent with nested params)
assert("async bulk_create: jobs enqueued", ActiveJob::Base.queue_adapter.enqueued_jobs.size >= 2)

# Execute all captured jobs
ActiveJob::Base.queue_adapter.enqueued_jobs.each do |jd|
  Railsmith::AsyncNestedWriteJob.perform_now(**jd[:args].first.transform_keys(&:to_sym))
end
assert("async bulk_create: comment A persisted after job", Comment.exists?(post_id: post_a.id, author: "BulkA"))
assert("async bulk_create: comment B persisted after job", Comment.exists?(post_id: post_b.id, author: "BulkB"))

# ── 38. REAL WORKER EXECUTION: RailsmithNestedWriteWorker ───────────────────
puts "\n=== 38. Real Sidekiq Worker Execution ==="

# The goal here is to verify the END-TO-END contract between the gem and the
# worker: the gem must produce a payload in a shape the worker can consume.
# Previous versions of this test hand-wrote a payload; that only proved the
# worker can accept a payload of the test author's imagination.
#
# To properly exercise the contract we:
#   1. Point async_job_class at RailsmithNestedWriteWorker and stub
#      perform_async so it captures the payload the gem produces.
#   2. Drive a normal service call — this is the gem's enqueue path.
#   3. Feed the captured payload back into an actual worker instance.
# That chain proves the gem's output is a valid input to the worker.

captured_worker_payloads = []
# Shadow .perform_async on the singleton class — fallback to Sidekiq::Worker's
# real perform_async is restored below by removing the shadow.
RailsmithNestedWriteWorker.define_singleton_method(:perform_async) do |payload|
  captured_worker_payloads << payload
  "real-jid-#{captured_worker_payloads.size}"
end

Railsmith.configuration.async_job_class = RailsmithNestedWriteWorker
Railsmith.configuration.async_enqueuer  = nil

rwrk = PostWithAsyncCommentsService.call(
  action: :create,
  params: {
    attributes: { title: "Worker Execution Post", status: "draft" },
    comments: [{ attributes: { author: "SidekiqReal", body: "Real worker test" } }]
  },
  context: { current_domain: :blog, request_id: "worker-req-1" }
)
assert("real worker: parent created through gem", rwrk.success?)
assert("real worker: gem routed to perform_async (payload captured)", captured_worker_payloads.size == 1)

captured_payload = captured_worker_payloads.first
assert("real worker: captured payload is a Hash", captured_payload.is_a?(Hash))

# The payload must carry the pieces the worker's perform needs.
pw_fetch = ->(key) { captured_payload[key] || captured_payload[key.to_s] || captured_payload[key.to_sym] }
assert("real worker: payload names service_class",  pw_fetch.call(:service_class).to_s == "PostWithAsyncCommentsService")
assert("real worker: payload carries parent_id",    pw_fetch.call(:parent_id) == rwrk.value.id)
assert("real worker: payload carries association",  pw_fetch.call(:association).to_s == "comments")
assert("real worker: payload carries mode :create", pw_fetch.call(:mode).to_s == "create")
assert("real worker: payload carries context",      pw_fetch.call(:context).is_a?(Hash))

# Child NOT written yet — perform_async was stubbed so nothing ran.
assert("real worker: child NOT yet persisted (we stubbed perform_async)", !Comment.exists?(post_id: rwrk.value.id, author: "SidekiqReal"))

# Restore perform_async (drop our shadow — Sidekiq::Worker's version resurfaces).
RailsmithNestedWriteWorker.singleton_class.send(:remove_method, :perform_async)

RailsmithNestedWriteWorker.new.perform(captured_payload)
assert("real worker: child persisted after worker#perform on gem-produced payload", Comment.exists?(post_id: rwrk.value.id, author: "SidekiqReal"))

# ── 39. REAL WORKER EXECUTION: RailsmithKicksPublisher.drain! ───────────────
puts "\n=== 39. Real Kicks Publisher Drain Execution ==="

# End-to-end: drive the gem's enqueue path so the PUBLISHED_MESSAGES queue
# gets a real gem-produced payload, then call drain! to actually process it.
# Previous revisions hand-built the payload, which proved nothing about the
# gem↔publisher contract.

Railsmith.configuration.async_job_class = RailsmithKicksPublisher
Railsmith.configuration.async_enqueuer  = ->(job_class, payload) { job_class.publish(payload) }
RailsmithKicksPublisher.clear!

rkrun = PostWithAsyncCommentsService.call(
  action: :create,
  params: {
    attributes: { title: "Kicks Execution Post", status: "draft" },
    comments: [{ attributes: { author: "KicksReal", body: "Real kicks test" } }]
  },
  context: { current_domain: :blog, request_id: "kicks-req-1" }
)
assert("real kicks: parent created through gem", rkrun.success?)
assert("real kicks: gem published exactly one message", RailsmithKicksPublisher::PUBLISHED_MESSAGES.size == 1)

# Inspect the gem-produced payload before draining it.
gem_produced = RailsmithKicksPublisher::PUBLISHED_MESSAGES.first
gem_fetch = ->(key) {
  next nil unless gem_produced.is_a?(Hash)
  gem_produced[key] || gem_produced[key.to_s] || gem_produced[key.to_sym]
}
assert("real kicks: payload carries service_class",     gem_fetch.call(:service_class).to_s == "PostWithAsyncCommentsService")
assert("real kicks: payload carries parent_id",         gem_fetch.call(:parent_id) == rkrun.value.id)
assert("real kicks: payload carries association name",  gem_fetch.call(:association).to_s == "comments")
assert("real kicks: payload carries :create mode",      gem_fetch.call(:mode).to_s == "create")
assert("real kicks: comment NOT yet persisted",         !Comment.exists?(post_id: rkrun.value.id, author: "KicksReal"))

RailsmithKicksPublisher.drain!
assert("real kicks: queue empty after drain",           RailsmithKicksPublisher::PUBLISHED_MESSAGES.empty?)
assert("real kicks: comment persisted after drain",     Comment.exists?(post_id: rkrun.value.id, author: "KicksReal"))

# ── 40. CONTEXT SERIALIZATION ROUND-TRIP ────────────────────────────────────
puts "\n=== 40. Context Serialization Round-Trip ==="

ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.queue_adapter.enqueued_jobs.clear
Railsmith.configuration.async_job_class = Railsmith::AsyncNestedWriteJob
Railsmith.configuration.async_enqueuer  = nil

# Rich context with various types
rich_context = {
  current_domain: :blog,
  request_id:     "roundtrip-req-abc",
  actor_id:       42,
  tenant_id:      "org-xyz",
  roles:          %w[admin editor]
}

# Intercept the job to inspect the serialized payload
rct1 = PostWithAsyncCommentsService.call(
  action: :create,
  params: {
    attributes: { title: "Context Roundtrip Post", status: "draft" },
    comments: [{ attributes: { author: "CtxRT", body: "Context roundtrip" } }]
  },
  context: rich_context
)
assert("context roundtrip: parent created", rct1.success?)

# Extract the job payload and inspect the serialized context
job_data_ctx = ActiveJob::Base.queue_adapter.enqueued_jobs.last
job_args = job_data_ctx[:args].first
serialized_ctx = job_args["context"] || job_args[:context]
rt_fetch = ->(key) { serialized_ctx[key] || serialized_ctx[key.to_s] || serialized_ctx[key.to_sym] }

assert("context roundtrip: request_id survives", rt_fetch.call(:request_id) == "roundtrip-req-abc")
assert("context roundtrip: actor_id survives",   rt_fetch.call(:actor_id)   == 42)
assert("context roundtrip: tenant_id survives",  rt_fetch.call(:tenant_id)  == "org-xyz")
# Arrays must survive ActiveJob's JSON serialization round-trip intact.
roles_roundtrip = rt_fetch.call(:roles)
assert(
  "context roundtrip: roles array survives serialization",
  roles_roundtrip.is_a?(Array) && roles_roundtrip.map(&:to_s).sort == %w[admin editor]
)

# Prove the context is actually rebuilt at job-run time — not just that the
# payload carried it. We wrap Railsmith::Context.build to observe what the
# job hands it, and then verify the nested write completed.
observed_rt_builds = []
Railsmith::Context.singleton_class.class_eval do
  alias_method :__orig_build_for_rt_probe, :build unless method_defined?(:__orig_build_for_rt_probe)
  define_method(:build) do |attrs = {}|
    observed_rt_builds << attrs
    __orig_build_for_rt_probe(attrs)
  end
end

Railsmith::AsyncNestedWriteJob.perform_now(**job_args.transform_keys(&:to_sym))

Railsmith::Context.singleton_class.class_eval do
  alias_method :build, :__orig_build_for_rt_probe
  remove_method :__orig_build_for_rt_probe
end

rt_build_match = observed_rt_builds.find do |h|
  h.is_a?(Hash) && (h[:request_id] || h["request_id"]) == "roundtrip-req-abc"
end
assert("context roundtrip: Context.build invoked with our request_id at job runtime", !rt_build_match.nil?)
assert("context roundtrip: child created successfully (context intact)", Comment.exists?(post_id: rct1.value.id, author: "CtxRT"))

# ── 41. ASYNC: enqueue path for .enqueue responder ──────────────────────────
puts "\n=== 41. Enqueue-style Backend ==="

fake_enqueue_backend = Class.new do
  class << self
    attr_accessor :jobs

    def enqueue(payload)
      @jobs ||= []
      handle = Struct.new(:job_id).new("enq-#{@jobs.size + 1}")
      @jobs << { payload: payload, handle: handle }
      handle
    end

    def reset!
      @jobs = []
    end
  end
end
fake_enqueue_backend.reset!

Railsmith.configuration.async_job_class = fake_enqueue_backend
Railsmith.configuration.async_enqueuer  = nil

ren1 = PostWithAsyncCommentsService.call(
  action: :create,
  params: {
    attributes: { title: "Enqueue Backend Post", status: "draft" },
    comments: [{ attributes: { author: "EnqStyle", body: "Enqueue test" } }]
  },
  context: ctx
)
assert("enqueue backend: parent created", ren1.success?)
assert("enqueue backend: job enqueued", fake_enqueue_backend.jobs.size == 1)
assert("enqueue backend: meta has job_id", ren1.meta.dig(:nested, :comments, :job_id) == "enq-1")

# Restore
restore_async_config!(original_async_job_class, original_async_enqueuer)
ActiveJob::Base.queue_adapter = previous_aj_adapter

# ── Summary ───────────────────────────────────────────────────────────────────
puts "\n=============================="
total = $pass_count + $failures.length
if $failures.empty?
  puts "All #{total} scenarios passed."
else
  puts "#{$failures.length}/#{total} FAILED:"
  $failures.each { |f| puts "  - #{f}" }
end
