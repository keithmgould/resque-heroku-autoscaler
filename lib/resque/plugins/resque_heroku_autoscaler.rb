require 'heroku-api'
require 'resque/plugins/heroku_autoscaler/config'

module Resque
  module Plugins
    module HerokuAutoscaler
      def config
        Resque::Plugins::HerokuAutoscaler::Config
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

      def set_workers(number_of_workers)
        return if (jobs_in_progress? && number_of_workers < current_workers) || number_of_workers == current_workers
        heroku_api.post_ps_scale(config.heroku_app, config.heroku_task, number_of_workers)
        Resque.redis.set('last_scaled', Time.now)
      end

      def scale
        new_count = config.new_worker_count(Resque.info[:pending])
        return if new_count >= current_workers && !time_to_scale?
        set_workers(new_count) if new_count == min_workers || new_count > current_workers
      end

      def scale_on_enqueue
        return if current_workers >= 0 && !time_to_scale?
        clear_stale_workers if current_workers == 0

        new_count = config.new_worker_count(Resque.info[:pending])
        if current_workers <= 0 || new_count > current_workers
          set_workers([new_count,min_workers,1].max)
        end
      end

      def heroku_api
        @heroku_api ||= ::Heroku::API.new(api_key: config.heroku_api_key)
      end

      def self.config
        yield Resque::Plugins::HerokuAutoscaler::Config
      end

      private

      def current_workers
        heroku_api.get_ps(config.heroku_app).body.count {|p| p['process'].match(/#{config.heroku_task}\.\d+/) }
      end

      def jobs_in_progress?
        working = Resque.info[:working] || 0
        working > 0
      end

      def min_workers
        [config.new_worker_count(0), 0].max
      end

      def clear_stale_workers
        Resque.workers.each do |w|
          w.done_working
          w.unregister_worker
        end
      end

      def time_to_scale?
        return true unless last_scaled = Resque.redis.get('last_scaled')
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
