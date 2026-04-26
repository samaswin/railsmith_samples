module QueryCounter
  IGNORED_PAYLOAD_NAMES = [
    "SCHEMA",
    "TRANSACTION",
    "ActiveRecord::InternalMetadata Load",
    "ActiveRecord::SchemaMigration Load"
  ].freeze

  def count_sql_queries(&block)
    count = 0

    callback = lambda do |_name, _start, _finish, _id, payload|
      next if IGNORED_PAYLOAD_NAMES.include?(payload[:name])
      next if payload[:cached]

      count += 1
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    count
  end
end

