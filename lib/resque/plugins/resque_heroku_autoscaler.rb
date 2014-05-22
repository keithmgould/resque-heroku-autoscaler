require 'heroku-api'
require 'resque/plugins/heroku_autoscaler/config'

module Resque
  module Plugins
    module HerokuAutoscaler
      def config
        Resque::Plugins::HerokuAutoscaler::Config
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

      def after_enqueue_scale_workers_up(*args)
        scale_on_enqueue unless config.scaling_disabled?
      end

      def after_perform_scale_workers(*args)
        scale unless config.scaling_disabled?
      end

      def on_failure_scale_workers(*args)
        scale unless config.scaling_disabled?
      end

      def set_workers(workers_needed_count)
        return if workers_needed_count == current_worker_count
        heroku_api.post_ps_scale(config.heroku_app, worker_name, workers_needed_count)
        Resque.redis.set("last_scaled_for_#{queue}", Time.now)
      end

      def scale
        return unless time_to_scale?
        new_count = config.new_worker_count(pending_count)
        set_workers(new_count)
      end

      def initialize_timer
        unless Resque.redis.get("last_scaled_for_#{queue}")
          Resque.redis.set("last_scaled_for_#{queue}", Time.now)
        end
      end

      def scale_on_enqueue
        initialize_timer
        scale
      end

      def heroku_api
        @heroku_api ||= ::Heroku::API.new(api_key: config.heroku_api_key)
      end

      def self.config
        yield Resque::Plugins::HerokuAutoscaler::Config
      end

      def current_worker_count
        Resque.workers.map(&:to_s).count { |p| p.split(":")[2] == queue.to_s  }
      end

      def time_to_scale?
        return true unless last_scaled = Resque.redis.get("last_scaled_for_#{queue}")
        return true if config.wait_time <= 0

        time_waited_so_far = Time.now - Time.parse(last_scaled)
        time_waited_so_far >=  config.wait_time || time_waited_so_far < 0
      end

      def log(message)
        if defined?(Rails)
          Rails.logger.info(message)
        else
          puts message
        end
      end
    end
  end
end
