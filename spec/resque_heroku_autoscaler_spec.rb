require 'spec_helper'

class TestJob
  extend Resque::Plugins::HerokuAutoscaler

  @queue = :test
end

class AnotherJob
  extend Resque::Plugins::HerokuAutoscaler

  @queue = :test
end

describe Resque::Plugins::HerokuAutoscaler do
  describe "scaling" do
    before do
      @fake_heroku_api = double(Heroku::API, :post_ps_scale => nil)
      Resque::Plugins::HerokuAutoscaler::Config.reset
      TestJob.stub(:heroku_api => @fake_heroku_api, :current_workers => 2)
    end

    it "should be a valid Resque plugin" do
      lambda { Resque::Plugin.lint(Resque::Plugins::HerokuAutoscaler) }.should_not raise_error
    end

    describe ".after_enqueue_scale_workers_up" do
      it "should add the hook" do
        Resque::Plugin.after_enqueue_hooks(TestJob).should include(:after_enqueue_scale_workers_up)
      end

      it "should take whatever args Resque hands in" do
        TestJob.stub(:heroku_api => @fake_heroku_api)
        TestJob.stub(:current_workers => 1)

        lambda do
          TestJob.after_enqueue_scale_workers_up("some", "random", "aguments", 42)
        end.should_not raise_error
      end

      it "should create workers to do all pending jobs" do
        Resque.redis.stub(:get).with('last_scaled').and_return((Time.now - 1.day).to_s)
        TestJob.stub(:current_workers => 4 )
        Resque.stub(:info => {:pending => 7, :working => 3})
        @fake_heroku_api.should_receive(:post_ps_scale).with(anything, anything, 6)
        TestJob.after_enqueue_scale_workers_up
      end

      it "should set last_scaled" do
        Resque.redis.set('last_scaled', Time.now- 1.day)
        now = Time.now
        Resque.redis.get('last_scaled').should_not == now.to_s
        Timecop.freeze(now)
        TestJob.after_enqueue_scale_workers_up
        Resque.redis.get('last_scaled').should == now.to_s
        Timecop.return
      end

      context "when scaling workers is disabled" do
        before do
          subject.config do |c|
            c.scaling_disabled = true
          end
        end

        it "should not use the heroku client" do
          TestJob.should_not_receive(:scale)
          TestJob.after_enqueue_scale_workers_up
        end
      end
    end

    describe ".after_perform_scale_workers" do
      before do
        Resque.redis.set('last_scaled', Time.now - 120)
      end

      it "should add the hook" do
        Resque::Plugin.after_hooks(TestJob).should include(:after_perform_scale_workers)
      end

      it "should take whatever args Resque hands in" do
        lambda { TestJob.after_perform_scale_workers("some", "random", "aguments", 42) }.should_not raise_error
      end
    end

    describe ".on_failure_scale_workers" do
      before do
        Resque.redis.set('last_scaled', Time.now - 120)
      end

      it "should add the hook" do
        Resque::Plugin.failure_hooks(TestJob).should include(:on_failure_scale_workers)
      end

      it "should take whatever args Resque hands in" do
        lambda { TestJob.on_failure_scale_workers("some", "random", "aguments", 42) }.should_not raise_error
      end
    end

    describe ".calculate_and_set_workers" do
      before do
        Resque.redis.set('last_scaled', Time.now - 120)
      end

      context "when the queue is empty" do
        before do
          @now = Time.now
          Timecop.freeze(@now)
          Resque.stub(:info => {:pending => 0} )
        end

        after { Timecop.return }

        it "should set workers to 0" do
          @fake_heroku_api.should_receive(:post_ps_scale).with(anything, anything, 0)
          TestJob.calculate_and_set_workers
        end

        it "sets last scaled time" do
          TestJob.stub(:set_workers => nil)
          TestJob.calculate_and_set_workers
          Resque.redis.get('last_scaled').should == @now.to_s
        end
      end

      context "when the queue is not empty" do
        before do
          Resque.stub(:info => {:pending => 1} )
        end

        it "should keep workers at 1" do
          @fake_heroku_api.should_receive(:post_ps_scale).with(anything, anything, 1)
          TestJob.stub(:current_workers => 0)
          TestJob.calculate_and_set_workers
        end

        context "when scaling workers is disabled" do
          before do
            subject.config do |c|
              c.scaling_disabled = true
            end
          end

          it "should not use the heroku client" do
            @fake_heroku_api.should_not_receive(:post_ps_scale)
            TestJob.calculate_and_set_workers
          end
        end
      end

      context "when multiple pending jobs" do
        before do
          TestJob.stub(:current_workers => 4 )
          Resque.stub(:info => {:pending => 7, :working =>2})
        end

        it "should use the given block" do
          @fake_heroku_api.should_receive(:post_ps_scale).with(anything, anything, 5)
          TestJob.calculate_and_set_workers
        end
      end

      context "when the new worker count might shut down busy workers" do
        before do
          TestJob.stub(:current_workers => 10)
          Resque.stub(:info => {:pending => 2, :working =>2})
        end

        it "should not scale down workers since we don't want to accidentally shut down busy workers" do
          @fake_heroku_api.should_not_receive(:post_ps_scale)
          TestJob.calculate_and_set_workers
        end
      end

      describe "when we changed the worker count in less than minimum wait time" do
        before do
          subject.config { |c| c.wait_between_scaling = 2}
          @last_set = Time.parse("00:00:00")
          Resque.redis.set('last_scaled', @last_set)
        end

        after { Timecop.return }

        it "should not adjust the worker count" do
          Timecop.freeze(@last_set + 1)
          TestJob.should_not_receive(:set_workers)
          TestJob.calculate_and_set_workers
        end
      end
    end

    describe ".set_workers" do
      it "should use the Heroku client to set the workers" do
        subject.config do |c|
          c.heroku_app = 'some_app_name'
        end

        TestJob.stub(:current_workers => 0)
        Resque.stub(:info => {:pending => 10, :working => 3})
        @fake_heroku_api.should_receive(:post_ps_scale).with('some_app_name', 'worker', 10)
        TestJob.should_receive(:heroku_api).and_return(@fake_heroku_api)
        TestJob.set_workers(10)
      end
    end
  end

  describe "config and api" do
    describe ".heroku_api" do
      before do
        subject.config do |c|
          c.heroku_api_key = 'abcdefg'
        end
      end

      it "should use the right username and password" do
        Resque::Plugins::HerokuAutoscaler.class_eval("@@heroku_api = nil")
        ::Heroku::API.should_receive(:new).with(api_key: 'abcdefg')
        TestJob.heroku_api
      end

      it "should return the same client for multiple jobs" do
        a = 0
        Heroku::API.should_receive(:new).and_return(a)
        TestJob.heroku_api.should == TestJob.heroku_api
      end

      it "should share the same client across differnet job types" do
        a = 0
        Heroku::API.should_receive(:new).and_return(a)
        TestJob.heroku_api.should == AnotherJob.heroku_api
      end
    end

    describe ".config" do
      it "yields the configuration" do
        subject.config do |c|
          c.should == Resque::Plugins::HerokuAutoscaler::Config
        end
      end
    end

    describe ".current_workers" do
      it "should request the numbers of active workers from Heroku" do
        subject.config do |c|
          c.heroku_app = "my_app"
        end

        body = [
          { "app_name" => "my_app", "process" => "web.1" },
          { "app_name" => "my_app", "process" => "worker.1" },
          { "app_name" => "my_app", "process" => "worker.2" },
        ]

        @fake_heroku_api = double(Heroku::API, :post_ps_scale => nil)
        @fake_heroku_api.should_receive(:get_ps).with('my_app').and_return(double(:body => body))
        TestJob.stub(:heroku_api => @fake_heroku_api)

        TestJob.current_workers.should == 2
      end
    end
  end
end
