require 'spec_helper'

class TestJob
  extend Resque::Plugins::HerokuAutoscaler
  @queue = :test
end

class AnotherJob
  extend Resque::Plugins::HerokuAutoscaler
  @queue = :another
end

describe Resque::Plugins::HerokuAutoscaler do

  it "should be a valid Resque plugin" do
    lambda { Resque::Plugin.lint(Resque::Plugins::HerokuAutoscaler) }.should_not raise_error
  end

  describe ".queue" do
    it "returns the name of the job's queue" do
      expect(TestJob.queue).to eq(:test)
      expect(AnotherJob.queue).to eq(:another)
    end
  end

  describe ".worker_name" do
    it 'is the name of the queue + worker' do
      TestJob.stub(:queue).and_return('foo')
      expect(TestJob.worker_name).to eq('fooworker')
    end
  end

  describe ".pending_count" do
    before { Resque.stub(:size).and_return(40) }

    it 'returns the count of pending jobs in the queue used by the current job' do
        expect(TestJob.pending_count).to eq(40)
    end
  end

  describe ".after_enqueue_scale_workers" do
    it "should add the hook" do
      Resque::Plugin.after_enqueue_hooks(TestJob).should include(:after_enqueue_scale_workers)
    end

    it "should take whatever args Resque hands in" do
      TestJob.stub(:heroku_api => @fake_heroku_api)

      lambda do
        TestJob.after_enqueue_scale_workers("some", "random", "aguments", 42)
      end.should_not raise_error
    end

    context "when scaling workers is disabled" do
      before do
        subject.config do |c|
          c.scaling_disabled = true
        end
      end

      it "should not use the heroku client" do
        TestJob.should_not_receive(:scale)
        TestJob.after_enqueue_scale_workers
      end
    end
  end

  describe ".after_perform_scale_workers" do
    before do
      Resque.redis.set('last_scaled_for_test', Time.now - 120)
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
      Resque.redis.set('last_scaled_for_test', Time.now - 120)
    end

    it "should add the hook" do
      Resque::Plugin.failure_hooks(TestJob).should include(:on_failure_scale_workers)
    end

    it "should take whatever args Resque hands in" do
      lambda { TestJob.on_failure_scale_workers("some", "random", "aguments", 42) }.should_not raise_error
    end
  end

  describe ".scale" do
    before do
      TestJob.stub(:add_workers).and_return true
      TestJob.stub(:remove_workers).and_return true
    end

    context 'it is not time to scale' do
      before { TestJob.stub(:time_to_scale?).and_return(false) }
      it 'does not set last scaled time' do
        TestJob.should_not_receive(:set_last_scaled_time)
        TestJob.scale
      end

      it 'does not change worker count' do
        TestJob.should_not_receive(:remove_workers)
        TestJob.should_not_receive(:add_workers)
        TestJob.scale
      end
    end

    context 'it is time to scale' do
      before { TestJob.stub(:time_to_scale?).and_return(true) }
      context 'new workers count equal to current workers count' do
        before do
          TestJob.config.stub(:new_worker_count).and_return(3)
          TestJob.stub(:current_workers).and_return [1,2,3]
        end

        it 'does not set the last scaled time' do
          TestJob.should_not_receive(:set_last_scaled_time)
          TestJob.scale
        end

        it 'does not add or remove workers' do
          TestJob.should_not_receive(:remove_workers)
          TestJob.should_not_receive(:add_workers)
          TestJob.scale
        end
      end

      context 'new workers greater than current workers' do
        before do
          TestJob.config.stub(:new_worker_count).and_return(5)
          TestJob.stub(:current_workers).and_return [1,2,3]
        end

        it 'adds workers' do
          TestJob.should_receive(:add_workers)
          TestJob.scale
        end

        it 'sets the last scaled time' do
          TestJob.should_receive(:set_last_scaled_time)
          TestJob.scale
        end
      end

      context 'new workers less than current workers' do
        before do
          TestJob.stub_chain(:config, :new_worker_count).and_return(2)
          TestJob.stub(:current_workers).and_return [1,2,3]
        end
        it 'removes workers' do
          TestJob.should_receive(:remove_workers)
          TestJob.scale
        end

        it 'sets the last scaled time' do
          TestJob.should_receive(:set_last_scaled_time)
          TestJob.scale
        end
      end
    end
  end

  describe ".add_workers" do
    before do
      @fake_heroku_api = double(Heroku::API, :post_ps_scale => nil)
    end

    it "should use the Heroku client to set the workers" do
      subject.config do |c|
        c.heroku_app = 'some_app_name'
      end

      TestJob.stub(:current_workers => 0)
      @fake_heroku_api.should_receive(:post_ps_scale).with('some_app_name', 'testworker', 10)
      TestJob.should_receive(:heroku_api).and_return(@fake_heroku_api)
      TestJob.add_workers(10)
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
      it "requests the numbers of active workers for a given queue from Heroku" do
        Resque.stub(:workers).and_return ["foo:bar:test", "foo:bar:test", "foo:bar:cheese"]
        expect(TestJob.current_workers).to eq(["foo:bar:test", "foo:bar:test"])
      end
    end
  end
end
