module Resque
  module Plugins
    module HerokuAutoscaler
      module Config
        extend self

        @scaling_disabled = false

        attr_writer :scaling_disabled

        attr_writer :min_workers
        def min_workers
          @min_workers || 0
        end

        attr_writer :max_workers
        def max_workers
          @max_workers || 0
        end

        def scaling_disabled?
          @scaling_disabled
        end

        attr_writer :heroku_api_key
        def heroku_api_key
          @heroku_api_key || ENV['HEROKU_API_KEY']
        end

        attr_writer :heroku_app
        def heroku_app
          @heroku_app || ENV['HEROKU_APP']
        end

        attr_writer :heroku_task
        def heroku_task
          @heroku_task || 'worker'
        end

        attr_writer :wait_between_scaling
        def wait_between_scaling
          @wait_between_scaling || 0
        end

        def reset
          @scaling_disabled = false
        end
      end
    end
  end
end
