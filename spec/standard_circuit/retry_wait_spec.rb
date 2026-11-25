require "spec_helper"
require "active_job"
require "active_job/test_helper"

RSpec.describe StandardCircuit::RetryWait do
  include ActiveJob::TestHelper

  before do
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.logger = Logger.new(IO::NULL)
    StandardCircuit.configure do |c|
      c.register(:stripe, cool_off_time: 45)
      c.register(:broker, cool_off_time: 120)
    end
  end

  def without_jitter(&block)
    allow(Kernel).to receive(:rand).and_return(0.0)
    block.call
  end

  it "never waits less than the circuit's cool-off" do
    wait = StandardCircuit.retry_wait(:stripe)

    without_jitter do
      expect(wait.call(1)).to eq(45)
      expect(wait.call(2)).to eq(45)
    end
  end

  it "keeps the polynomial backoff once it is longer than the cool-off" do
    without_jitter { expect(StandardCircuit.retry_wait(:stripe).call(3)).to eq((3**4) + 2) }
  end

  it "floors at the longest cool-off of several circuits" do
    without_jitter { expect(StandardCircuit.retry_wait(:stripe, :broker).call(1)).to eq(120) }
  end

  it "reads the cool-off at retry time, so a later configure carries over" do
    wait = StandardCircuit.retry_wait(:stripe)
    StandardCircuit.configure { |c| c.register(:stripe, cool_off_time: 300) }

    without_jitter { expect(wait.call(1)).to eq(300) }
  end

  it "adds jitter on top of the floor, never below it" do
    allow(Kernel).to receive(:rand).and_return(1.0)

    expect(StandardCircuit.retry_wait(:stripe, jitter: 0.5).call(1)).to eq(45 + 22.5)
  end

  it "defaults the jitter to ActiveJob::Base.retry_jitter" do
    allow(Kernel).to receive(:rand).and_return(1.0)
    allow(ActiveJob::Base).to receive(:retry_jitter).and_return(0.2)

    expect(StandardCircuit.retry_wait(:stripe).call(1)).to eq(45 * 1.2)
  end

  it "takes jitter: 0 for an exact wait" do
    allow(Kernel).to receive(:rand).and_return(1.0)

    expect(StandardCircuit.retry_wait(:stripe, jitter: 0).call(1)).to eq(45)
  end

  it "uses the longest breaker of a dependency, isolated purposes included" do
    StandardCircuit.configure do |c|
      c.dependency(:ruby_llm, cool_off_time: 30) do |d|
        d.purpose :primary, default: true
        d.purpose :fallback, isolate: true, cool_off_time: 90
      end
    end

    without_jitter do
      expect(StandardCircuit.retry_wait(:ruby_llm).call(1)).to eq(90)
      expect(StandardCircuit.retry_wait(:ruby_llm_fallback).call(1)).to eq(90)
    end
  end

  it "resolves a prefix and its sub-circuits" do
    StandardCircuit.configure { |c| c.register_prefix(:s3, cool_off_time: 60) }

    without_jitter do
      expect(StandardCircuit.retry_wait(:s3).call(1)).to eq(60)
      expect(StandardCircuit.retry_wait(:s3_uploads).call(1)).to eq(60)
    end
  end

  it "raises UnknownCircuit at retry time for a name nothing registered" do
    wait = StandardCircuit.retry_wait(:nope)

    expect { wait.call(1) }.to raise_error(StandardCircuit::UnknownCircuit, /:nope/)
  end

  it "rejects no names and a bad jitter up front" do
    expect { StandardCircuit.retry_wait }.to raise_error(ArgumentError, /at least one/)
    expect { StandardCircuit.retry_wait(:stripe, jitter: -1) }.to raise_error(ArgumentError, /jitter/)
    expect { StandardCircuit.retry_wait(:stripe, jitter: "0.1") }.to raise_error(ArgumentError, /jitter/)
  end

  it "schedules an ActiveJob retry_on RedLight no sooner than the cool-off" do
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "RetryWaitSpecJob"

      retry_on Stoplight::Error::RedLight, wait: StandardCircuit.retry_wait(:stripe), attempts: 3

      def perform
        StandardCircuit.run(:stripe) { :charged }
      end
    end
    StandardCircuit.dependency(:stripe).lock_open!

    freeze = Time.now
    allow(Time).to receive(:now).and_return(freeze)
    job_class.perform_now

    retry_job = enqueued_jobs.find { |job| job[:job] == job_class }
    expect(retry_job).not_to be_nil
    delay = retry_job[:at] - freeze.to_f
    expect(delay).to be_between(45, 45 * 1.15 + 1)
  end
end
