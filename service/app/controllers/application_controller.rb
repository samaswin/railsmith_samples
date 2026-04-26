class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  around_action :record_sql_queries, if: :record_sql_queries?

  private

  def record_sql_queries?
    return false if Rails.env.production?

    params[:sql].present? || is_a?(UsersController)
  end

  def record_sql_queries
    @sql_queries = []

    ignored_names = [
      "SCHEMA",
      "TRANSACTION",
      "ActiveRecord::InternalMetadata Load",
      "ActiveRecord::SchemaMigration Load"
    ].freeze

    callback = lambda do |_name, _start, _finish, _id, payload|
      return if payload[:cached]
      return if ignored_names.include?(payload[:name])

      sql = payload[:sql].to_s.strip
      return if sql.empty?

      @sql_queries << sql
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
  end
end
