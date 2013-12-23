require 'heroku-api'
require 'resque/plugins/heroku_autoscaler/config'

module Resque
  module Plugins
    module HerokuAutoscaler
      def config
        Resque::Plugins::HerokuAutoscaler::Config
      end

      def after_enqueue_scale_workers_up(*args)
        calculate_and_set_workers
      end

      def before_perform_scale_workers(*args)
        calculate_and_set_workers
      end

      def after_perform_scale_workers(*args)
        calculate_and_set_workers
      end

      def on_failure_scale_workers(*args)
        calculate_and_set_workers
      end

      def calculate_and_set_workers
        return if config.scaling_disabled? || scaling_in_progress? || !time_to_scale?
        clear_stale_workers if current_workers == 0

        Resque.redis.set('resque_scaling', Time.now)
        Resque.redis.set('last_scaled', Time.now)
        new_count = Resque.info[:pending].to_i - free_workers
        new_count = config.max_workers if config.max_workers > 0 && new_count > config.max_workers
        new_count = config.min_workers if new_count < config.min_workers
        new_count = 0 if new_count < 0

        set_workers(new_count)
        Resque.redis.del('resque_scaling')
      end

      def set_workers(number_of_workers)
        return if number_of_workers == current_workers
        return if number_of_workers < current_workers && Resque.info[:pending].to_i > 0
        return if number_of_workers > current_workers && Resque.info[:pending].to_i <= 0

        heroku_api.post_ps_scale(config.heroku_app, config.heroku_task, number_of_workers)
      end

      def current_workers
        heroku_api.get_ps(config.heroku_app).body.count {|p| p['process'].match(/#{config.heroku_task}\.\d+/) }
      end

      def heroku_api
        @heroku_api ||= ::Heroku::API.new(api_key: config.heroku_api_key)
      end

      def self.config
        yield Resque::Plugins::HerokuAutoscaler::Config
      end

      private

      def scaling_in_progress?
        return false unless scaling_time = Resque.redis.get('resque_scaling')
        time_waited_so_far = Time.now - Time.parse(scaling_time)
        if time_waited_so_far > 30
          Resque.redis.del('resque_scaling')
        else
          true
        end
      end

      def clear_stale_workers
        Resque.workers.each do |w|
          w.done_working
          w.unregister_worker
        end
      end

      def free_workers
        [current_workers - Resque.info[:working].to_i, 0].max
      end

      def time_to_scale?
        return true unless last_scaled = Resque.redis.get('last_scaled')
        time_waited_so_far = Time.now - Time.parse(last_scaled)
        time_waited_so_far >=  config.wait_between_scaling || time_waited_so_far < 0
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
