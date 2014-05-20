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

      def set_workers(number_of_workers_needed)
        return if number_of_workers_needed == current_workers

        if number_of_workers_needed < current_workers && pending_count == 0
          heroku_api.post_ps_scale(config.heroku_app, worker_name, 0)
          wait_for_current_workers_to_go_zero
          clear_stale_workers
          heroku_api.post_ps_scale(config.heroku_app, worker_name, number_of_workers_needed) if number_of_workers_needed != 0
        else
          heroku_api.post_ps_scale(config.heroku_app, worker_name, number_of_workers_needed)
        end

        Resque.redis.set("last_scaled_for_#{queue}", Time.now)
      end

      def scale
        return unless time_to_scale?
        new_count = config.new_worker_count(pending_count)
        set_workers(new_count) if new_count != current_workers
      end

      def scale_on_enqueue
        # If we have already set the scale time,
        # check if it is now scale time.  Otherwise,
        # set scale time.
        if Resque.redis.get("last_scaled_for_#{queue}")
          return unless time_to_scale?
        else
          Resque.redis.set("last_scaled_for_#{queue}", Time.now)
        end

        new_count = config.new_worker_count(pending_count)
        set_workers([new_count,1].max) if new_count != current_workers
      end

      def heroku_api
        @heroku_api ||= ::Heroku::API.new(api_key: config.heroku_api_key)
      end

      def self.config
        yield Resque::Plugins::HerokuAutoscaler::Config
      end

      def wait_for_current_workers_to_go_zero
        tries = 0
        until current_workers == 0 || tries == 4
          tries += 1
          Kernel.sleep(0.5)
        end
      end

      def current_workers
        Resque.workers.map(&:to_s).count { |p| p.split(":")[2] == queue.to_s  }
      end

      def clear_stale_workers
        Resque.workers.each do |w|
          if w.to_s.split(":")[2] == queue.to_s
            w.done_working
            w.unregister_worker
          end
        end
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
