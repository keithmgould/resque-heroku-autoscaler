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
        
        if number_of_workers < current_workers
          heroku_api.post_ps_scale(config.heroku_app, config.heroku_task, 0)
          wait_for_current_workers_to_go_zero
          clear_stale_workers
          heroku_api.post_ps_scale(config.heroku_app, config.heroku_task, number_of_workers) if number_of_workers != 0
        else
          heroku_api.post_ps_scale(config.heroku_app, config.heroku_task, number_of_workers)
        end
        Resque.redis.set('last_scaled', Time.now)
      end

      def scale
        return if scaling_in_progress?
        Resque.redis.set('resque_scaling', Time.now)
        clear_stale_workers if current_workers == 0
        new_count = config.new_worker_count(Resque.info[:pending])
        return if new_count >= current_workers && !time_to_scale?
        set_workers(new_count) if new_count == min_workers || new_count > current_workers
        Resque.redis.del('resque_scaling')
      end

      def scale_on_enqueue
        return if current_workers > 0 && !time_to_scale?
        Resque.redis.set('resque_scaling', Time.now)
        clear_stale_workers if current_workers == 0

        new_count = config.new_worker_count(Resque.info[:pending])
        if current_workers <= 0 || new_count > current_workers
          set_workers([new_count,min_workers,1].max)
        end
        Resque.redis.del('resque_scaling')
      end

      def heroku_api
        @heroku_api ||= ::Heroku::API.new(api_key: config.heroku_api_key)
      end

      def self.config
        yield Resque::Plugins::HerokuAutoscaler::Config
      end

      private

      def wait_for_current_workers_to_go_zero
        tries = 0
        until current_workers == 0 || tries == 4
          tries += 1
          Kernel.sleep(0.5)
        end
      end

      def current_workers
        heroku_api.get_ps(config.heroku_app).body.count {|p| p['process'].match(/#{config.heroku_task}\.\d+/) }
      end

      def jobs_in_progress?
        workers = Resque.info[:workers] || current_workers
        working = Resque.info[:working] || 0

        out_of_sync_number = [workers - current_workers, 0].max
        working - out_of_sync_number > 1
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

      def scaling_in_progress?
        return false unless scaling_time = Resque.redis.get('resque_scaling')
        time_waited_so_far = Time.now - Time.parse(scaling_time)
        if time_waited_so_far > 30
          Resque.redis.del('resque_scaling')
          false
        else
          true
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
