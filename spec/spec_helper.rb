require 'rspec'
require 'heroku-api'
require 'resque'
require 'timecop'
require 'active_support/all'
require 'resque/plugins/heroku_autoscaler/config'
require 'resque/plugins/resque_heroku_autoscaler'

RSpec.configure do |config|
  config.before(:each) do
    Resque.redis.del('resque_scaling')
    Resque.redis.del('last_scaled')
  end
  
end
