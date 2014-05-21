require 'heroku-api'
require 'resque/plugins/heroku_autoscaler/config'

module Resque
  module Plugins
    module HerokuAutoscaler
      def config
        Resque::Plugins::HerokuAutoscaler::Config
      end

      def self.config
        yield Resque::Plugins::HerokuAutoscaler::Config
      end

      def heroku_api
        @heroku_api ||= ::Heroku::API.new(api_key: config.heroku_api_key)
      end

      def queue
        self.instance_variable_get("@queue")
      end

      def worker_name
        "#{queue}worker"
      end

      def pending_count
        Resque.size(queue)
      end

      def after_enqueue_scale_workers(*args)
        scale_on_enqueue unless config.scaling_disabled?
      end

      def after_perform_scale_workers(*args)
        scale unless config.scaling_disabled?
      end

      def on_failure_scale_workers(*args)
        scale unless config.scaling_disabled?
      end

      def add_workers(workers_needed_count)
        heroku_api.post_ps_scale(config.heroku_app, worker_name, workers_needed_count)
      end

      # lets process finish gracefully:
      # http://rubydoc.info/github/defunkt/resque/Resque/Worker:shutdown
      def remove_workers(workers_to_remove_count)
        workers_to_remove = current_workers.first(workers_to_remove_count)
        workers_to_remove.each { |worker| worker.shutdown }
      end

      def scale
        return unless time_to_scale?
        new_workers_count     = config.new_worker_count(pending_count)
        current_workers_count = current_workers.count

        if new_workers_count == current_workers_count
          return
        elsif new_workers_count > current_workers_count
          add_workers(new_workers_count)
        else
          remove_workers(current_workers_count - new_workers_count)
        end

        set_last_scaled_time
      end

      def scale_on_enqueue
        initialize_timer
        scale
      end

      def set_last_scaled_time
        Resque.redis.set("last_scaled_for_#{queue}", Time.now)
      end

      def initialize_timer
        unless Resque.redis.get("last_scaled_for_#{queue}")
          set_last_scaled_time
        end
      end

      def current_workers
        Resque.workers.map(&:to_s).select { |p| p.split(":")[2] == queue.to_s  }
      end

      def time_to_scale?
        return true unless last_scaled = Resque.redis.get("last_scaled_for_#{queue}")
        return true if config.wait_time <= 0

        time_waited_so_far = Time.now - Time.parse(last_scaled)
        time_waited_so_far >=  config.wait_time || time_waited_so_far < 0
      end
    end
  end
end
