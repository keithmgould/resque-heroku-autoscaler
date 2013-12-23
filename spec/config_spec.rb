require 'spec_helper'

describe Resque::Plugins::HerokuAutoscaler::Config do
  describe ".heroku_api_key" do
    it "stores the given heroku api key" do
      subject.heroku_api_key = "abcd"
      subject.heroku_api_key.should == "abcd"
    end

    it "defaults to HEROKU_API_KEY environment variable" do
      subject.heroku_api_key = nil
      ENV["HEROKU_API_KEY"]  = "abcdef"
      subject.heroku_api_key.should == "abcdef"
    end
  end

  describe ".heroku_app" do
    it "stores the given heroku application name" do
      subject.heroku_app = "my-grand-app"
      subject.heroku_app.should == "my-grand-app"
    end

    it "defaults to HEROKU_APP environment variable" do
      subject.heroku_app = nil
      ENV["HEROKU_APP"]  = "yaa"
      subject.heroku_app.should == "yaa"
    end
  end

  describe ".heroku_task" do
    it "stores the given heroku task name" do
      subject.heroku_task = "resque"
      subject.heroku_task.should == "resque"
    end

    it "defaults to worker" do
      subject.heroku_task = nil
      subject.heroku_task.should == "worker"
    end
  end

  describe ".scaling_disabled?" do

    it{ Resque::Plugins::HerokuAutoscaler::Config.scaling_disabled?.should be_false}

    it "sets scaling to disabled" do
      subject.scaling_disabled = true
      subject.scaling_disabled?.should be_true
    end
  end

  describe ".wait_between_scaling" do

    it{ Resque::Plugins::HerokuAutoscaler::Config.wait_between_scaling.should == 0}

    it "can be set" do
      subject.wait_between_scaling = 15
      subject.wait_between_scaling.should == 15
    end
  end
end
