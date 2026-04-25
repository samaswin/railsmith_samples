# frozen_string_literal: true

# Demonstrates: async nested writes via `async: true` on has_many.
#
# When a post is created or updated with nested comments, the comment
# writes are enqueued as a background job AFTER the parent transaction
# commits, instead of running inline.
#
# Key differences from PostWithCommentsService:
# - Comments are written asynchronously (parent doesn't wait)
# - Child failures cannot roll back the parent
# - Cannot use dependent: :destroy/:restrict with async
# - Requires config.async_job_class to be set
class PostWithAsyncCommentsService < Railsmith::BaseService
  model Post
  domain :blog

  has_many :comments, service: CommentService, async: true
end
