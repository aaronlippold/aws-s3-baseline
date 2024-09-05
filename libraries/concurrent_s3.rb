require "concurrent"
require "aws-sdk-s3"

module Aws::S3
  class Bucket
    def objects(options = {})
      options = options.merge(bucket: @name)
      resp = @client.list_objects_v2(options)

      # Check if the response contains any objects
      return ObjectSummary::Collection.new([]) if resp.contents.empty?

      pool = Concurrent::FixedThreadPool.new(16)
      log_thread_pool_status(pool, "Initialized")

      batches =
        Enumerator.new do |y|
          resp.each_page do |page|
            batch = Concurrent::Array.new
            page.data.contents.each do |c|
              begin
                pool.post do
                  begin
                    batch << ObjectSummary.new(
                      bucket_name: @name,
                      key: c.key,
                      data: c,
                      client: @client
                    )
                  rescue => e
                    # Handle or log the error
                    Inspec::Log.error "Error processing object #{c.key}: #{e.message}"
                    Inspec::Log.error "Backtrace: #{e.backtrace.join("\n")}"
                  end
                end
              rescue Concurrent::RejectedExecutionError => e
                # Handle the rejected execution error
                Inspec::Log.error "Task submission rejected for object #{c.key}: #{e.message}"
                log_thread_pool_status(pool, "RejectedExecutionError")
              end
            end
            pool.shutdown
            pool.wait_for_termination
            y.yield(batch)
          end
        end
      ObjectSummary::Collection.new(batches)
    ensure
      pool.shutdown if pool
    end

    private

    def log_thread_pool_status(pool, context)
      Inspec::Log.error "Thread pool status (#{context}):"
      Inspec::Log.error "  Pool size: #{pool.length}"
      Inspec::Log.error "  Queue length: #{pool.queue_length}"
      Inspec::Log.error "  Completed tasks: #{pool.completed_task_count}"
    end
  end
end

def get_public_objects(myBucket)
  myPublicKeys = Concurrent::Array.new
  s3 = Aws::S3::Resource.new
  pool = Concurrent::FixedThreadPool.new(56)
  log_thread_pool_status(pool, "Initialized")
  debug_mode = Inspec::Log.level == :debug

  bucket = s3.bucket(myBucket)
  object_count = bucket.objects.count

  if debug_mode
    Inspec::Log.debug "### Processing Bucket ### : #{myBucket} with #{object_count} objects"
  end

  # Check if the bucket has no objects
  return myPublicKeys if object_count.zero?

  bucket.objects.each do |object|
    Inspec::Log.debug "    Examining Key: #{object.key}" if debug_mode
    begin
      pool.post do
        begin
          grants = object.acl.grants
          if grants.map { |x| x.grantee.type }.any? { |x| x =~ /Group/ } &&
               grants
                 .map { |x| x.grantee.uri }
                 .any? { |x| x =~ /AllUsers|AuthenticatedUsers/ }
            myPublicKeys << object.key
          end
        rescue Aws::S3::Errors::AccessDenied => e
          # Handle access denied error
          Inspec::Log.error "Access denied for object #{object.key}: #{e.message}"
        rescue => e
          # Handle or log other errors
          Inspec::Log.error "Error processing object #{object.key}: #{e.message}"
          Inspec::Log.error "Backtrace: #{e.backtrace.join("\n")}"
        end
      end
    rescue Concurrent::RejectedExecutionError => e
      # Handle the rejected execution error
      Inspec::Log.error "Task submission rejected for object #{object.key}: #{e.message}"
      log_thread_pool_status(pool, "RejectedExecutionError")
    end
  end

  # Ensure all tasks are completed before shutting down the pool
  pool.shutdown
  pool.wait_for_termination
  myPublicKeys
ensure
  pool.shutdown if pool
end

def log_thread_pool_status(pool, context)
  Inspec::Log.error "Thread pool status (#{context}):"
  Inspec::Log.error "  Pool size: #{pool.length}"
  Inspec::Log.error "  Queue length: #{pool.queue_length}"
  Inspec::Log.error "  Completed tasks: #{pool.completed_task_count}"
end
