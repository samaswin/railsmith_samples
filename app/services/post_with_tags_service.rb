# frozen_string_literal: true

# Demonstrates: eager loading (includes DSL) + includes across associations.
class PostWithTagsService < Railsmith::BaseService
  model Post
  domain :blog

  includes :tags, :comments
end
