require "spec_helper"

# Locks a test suite can't leak (0.8.1): reset_locks!, the block form of
# lock_open! / lock_closed!, `purposes:` on Dependency locks, and the warning
# when a call meets a lock an earlier example left behind.
RSpec.describe StandardCircuit::Dependency do
  def dependency(name) = StandardCircuit.dependency(name)

  def red?(name)
    StandardCircuit.run(name) { :ran }
    false
  rescue Stoplight::Error::RedLight
    true
  end

  before do
    StandardCircuit.configure do |c|
      c.register(:stripe)
      c.dependency(:ruby_llm, cool_off_time: 30) do |d|
        d.purpose :primary, criticality: :critical, default: true
        d.purpose :fallback, isolate: true
      end
    end
  end

  describe "StandardCircuit.reset_locks!" do
    it "unlocks every circuit locked through a dependency or a purpose" do
      dependency(:stripe).lock_open!
      dependency(:ruby_llm).purpose(:fallback).lock_closed!

      StandardCircuit.reset_locks!

      expect(dependency(:stripe).circuits.first).to include(locked: false)
      expect(dependency(:ruby_llm).purpose(:fallback).circuits.first).to include(locked: false)
      expect(StandardCircuit.runner.locked_circuits).to be_empty
      expect(red?(:stripe)).to be(false)
    end

    it "leaves forced states alone and is a no-op with nothing locked" do
      StandardCircuit.force_open(:stripe)

      expect { StandardCircuit.reset_locks! }.not_to raise_error
      expect(red?(:stripe)).to be(true)
    end

    it "forgets locks that reset! dropped with the Memory store" do
      dependency(:stripe).lock_open!
      StandardCircuit.reset!

      expect(StandardCircuit.runner.locked_circuits).to be_empty
    end

    it "keeps tracking a lock whose unlock failed, so reset_locks! can retry it" do
      dependency(:stripe).lock_open!
      light = StandardCircuit.runner.light_for(:stripe)
      allow(light).to receive(:unlock).and_raise(IOError, "store down")

      expect { StandardCircuit.reset_locks! }.to raise_error(IOError)
      expect(StandardCircuit.runner.locked_circuits).to eq([ :stripe ])

      allow(light).to receive(:unlock).and_call_original
      StandardCircuit.reset_locks!
      expect(StandardCircuit.runner.locked_circuits).to be_empty
      expect(red?(:stripe)).to be(false)
    end

    it "stops tracking a circuit once it is unlocked" do
      dependency(:stripe).lock_open!
      dependency(:stripe).unlock!

      expect(StandardCircuit.runner.locked_circuits).to be_empty
    end
  end

  describe "the block form" do
    it "locks only for the block and returns the block's value" do
      result = dependency(:stripe).lock_open! { red?(:stripe) ? :was_red : :was_green }

      expect(result).to eq(:was_red)
      expect(red?(:stripe)).to be(false)
      expect(StandardCircuit.runner.locked_circuits).to be_empty
    end

    it "unlocks even when the block raises" do
      expect { dependency(:stripe).lock_open! { raise ArgumentError, "boom" } }.to raise_error(ArgumentError)

      expect(red?(:stripe)).to be(false)
    end

    it "works for lock_closed! and for a purpose" do
      expect(dependency(:stripe).lock_closed! { dependency(:stripe).circuits.first[:locked] }).to be(true)
      expect(dependency(:ruby_llm).purpose(:fallback).lock_open! { red?(:ruby_llm_fallback) }).to be(true)

      expect(red?(:ruby_llm_fallback)).to be(false)
    end

    it "puts an enclosing lock back when a nested block ends" do
      dep = dependency(:stripe)

      dep.lock_open! do
        dep.lock_closed! { expect(red?(:stripe)).to be(false) }
        expect(red?(:stripe)).to be(true)
      end
      expect(red?(:stripe)).to be(false)
      expect(StandardCircuit.runner.locked_circuits).to be_empty
    end

    it "keeps a dependency-wide lock when a purpose block on a shared breaker ends" do
      llm = dependency(:ruby_llm)
      llm.lock_open!

      llm.purpose(:primary).lock_closed! { expect(red?(:ruby_llm)).to be(false) }

      expect(red?(:ruby_llm)).to be(true)
      expect(red?(:ruby_llm_fallback)).to be(true)
    end

    it "still returns the handle without a block, so calls chain" do
      dep = dependency(:stripe)
      purpose = dep.purpose(:default)

      expect(dep.lock_open!).to be(dep)
      expect(purpose.lock_closed!.unlock!).to be(purpose)
    end
  end

  describe "purposes:" do
    it "locks every breaker by default, isolated purposes included, so open? is true" do
      dependency(:ruby_llm).lock_open!

      expect(red?(:ruby_llm)).to be(true)
      expect(red?(:ruby_llm_fallback)).to be(true)
      expect(dependency(:ruby_llm)).to be_open
    end

    it "locks only the named purposes' breakers" do
      dependency(:ruby_llm).lock_open!(purposes: :primary)

      expect(red?(:ruby_llm)).to be(true)
      expect(red?(:ruby_llm_fallback)).to be(false)
      expect(dependency(:ruby_llm)).not_to be_open
    end

    it "takes several purposes, and unlocks by purpose too" do
      dependency(:ruby_llm).lock_open!(purposes: [ :primary, :fallback ])
      dependency(:ruby_llm).unlock!(purposes: :fallback)

      expect(red?(:ruby_llm)).to be(true)
      expect(red?(:ruby_llm_fallback)).to be(false)
    end

    it "raises UnknownPurpose for a purpose the dependency doesn't declare, locking nothing" do
      expect { dependency(:ruby_llm).lock_open!(purposes: [ :primary, :nope ]) }
        .to raise_error(StandardCircuit::UnknownPurpose)
      expect(red?(:ruby_llm)).to be(false)
    end
  end

  describe "the leaked-lock warning" do
    let(:config) do
      StandardCircuit::Config.new.tap { |c| c.register(:svc) }
    end
    let(:runner) { StandardCircuit::Runner.new(config) }
    let(:earlier_example) { instance_double(RSpec::Core::Example, location: "./spec/earlier_spec.rb:12") }

    def run_svc
      runner.run(:svc) { :ran }
    rescue Stoplight::Error::RedLight
      :red
    end

    it "warns once when a call meets a lock an earlier example made" do
      allow(RSpec).to receive(:current_example).and_return(earlier_example)
      runner.lock(:svc, :open)
      allow(RSpec).to receive(:current_example).and_call_original

      expect { run_svc }.to output(%r{:svc is still locked by an earlier example \(\./spec/earlier_spec\.rb:12\)}).to_stderr
      expect { run_svc }.not_to output.to_stderr
    end

    it "stays quiet for a lock made in the same example" do
      runner.lock(:svc, :open)

      expect { run_svc }.not_to output.to_stderr
    end

    it "stays quiet once the lock is cleared" do
      allow(RSpec).to receive(:current_example).and_return(earlier_example)
      runner.lock(:svc, :open)
      allow(RSpec).to receive(:current_example).and_call_original
      runner.reset_locks!

      expect { run_svc }.not_to output.to_stderr
    end

    it "stays quiet for a lock made outside any example" do
      allow(RSpec).to receive(:current_example).and_return(nil)
      runner.lock(:svc, :open)
      allow(RSpec).to receive(:current_example).and_call_original

      expect { run_svc }.not_to output.to_stderr
    end
  end
end
