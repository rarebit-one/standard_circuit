require "spec_helper"
require "open3"
require "rbconfig"

# The runner registers its lights in Stoplight systems through the public
# `Stoplight.register_system` only. A system name cannot be reused or
# unregistered, so a rebuild registers the next generation (`standard_circuit`,
# `standard_circuit_2`, ...), and a configure that changes nothing keeps the
# current system and its breaker state.
RSpec.describe StandardCircuit::Runner do
  describe "system generations" do
    def runner = StandardCircuit.runner
    def color(name) = runner.light_for(name).color

    def fail_once(name)
      StandardCircuit.run(name) { raise "boom" }
    rescue RuntimeError, Stoplight::Error::RedLight
      nil
    end

    def configure_flaky(threshold: 2)
      StandardCircuit.configure do |c|
        c.register(:flaky, threshold: threshold, cool_off_time: 60, tracked_errors: [ RuntimeError ])
      end
    end

    # Runs +script+ in a fresh Ruby process with this bundle, so a boot-time or
    # process-global setup can't leak into the rest of the suite.
    def run_in_fresh_process(script)
      lib = File.expand_path("../../lib", __dir__)
      output, status = Open3.capture2e(RbConfig.ruby, "-I#{lib}", "-e", script)
      expect(status).to be_success, output
      output
    end

    it "uses no stoplight constant outside its public API, bar the test helper's reset" do
      lib = File.expand_path("../../lib", __dir__)
      sources = Dir[File.join(lib, "**", "*.rb")].to_h { |file| [ file.delete_prefix("#{lib}/"), File.read(file) ] }

      expect(sources.select { |_, source| source.include?("Wiring::") }.keys).to be_empty
      expect(sources.select { |_, source| source.include?("__stoplight__") }.keys).to eq([ "standard_circuit/rspec.rb" ])
    end

    describe "a configure that changes nothing" do
      before { configure_flaky }

      it "keeps the system, failure counts and open circuits" do
        fail_once(:flaky)
        name = runner.system_name

        configure_flaky
        fail_once(:flaky)

        expect(runner.system_name).to eq(name)
        expect(color(:flaky)).to eq(Stoplight::Color::RED)

        configure_flaky
        expect(runner.system_name).to eq(name)
        expect(color(:flaky)).to eq(Stoplight::Color::RED)
      end

      it "keeps locks" do
        runner.lock(:flaky, :open)
        name = runner.system_name

        configure_flaky

        expect(runner.system_name).to eq(name)
        expect(runner.circuit_state(:flaky)).to include(color: "red", locked: true)
      end

      it "keeps everyone's state when it only adds a circuit" do
        2.times { fail_once(:flaky) }
        name = runner.system_name

        StandardCircuit.configure { |c| c.register(:other) }

        expect(StandardCircuit.run(:other) { :ok }).to eq(:ok)
        expect(runner.system_name).to eq(name)
        expect(color(:flaky)).to eq(Stoplight::Color::RED)
      end
    end

    describe "a configure that changes a circuit in use" do
      before { configure_flaky }

      it "discards breaker state in a new generation, and the new settings take effect" do
        2.times { fail_once(:flaky) }
        expect(color(:flaky)).to eq(Stoplight::Color::RED)
        name = runner.system_name

        configure_flaky(threshold: 3)

        expect(color(:flaky)).to eq(Stoplight::Color::GREEN)
        expect(runner.system_name).not_to eq(name)
        2.times { fail_once(:flaky) }
        expect(color(:flaky)).to eq(Stoplight::Color::GREEN)
        fail_once(:flaky)
        expect(color(:flaky)).to eq(Stoplight::Color::RED)
      end

      it "discards it when a circuit in use is no longer registered, leaving no trace in health_report" do
        StandardCircuit.run(:flaky) { :ok }
        name = runner.system_name

        StandardCircuit.config.reset_registry!
        StandardCircuit.configure { |c| c.register(:other) }

        expect(StandardCircuit.health_report[:circuits].map { |circuit| circuit[:name] }).to eq([ :other ])
        expect(runner.system_name).not_to eq(name)
      end
    end

    describe "reset!" do
      before { configure_flaky }

      it "leaves every circuit green with zero failures" do
        fail_once(:flaky)
        StandardCircuit.reset!
        fail_once(:flaky)
        expect(color(:flaky)).to eq(Stoplight::Color::GREEN)

        2.times { fail_once(:flaky) }
        StandardCircuit.reset!
        expect(color(:flaky)).to eq(Stoplight::Color::GREEN)
      end

      it "registers no new system when no circuit was used since the last one" do
        StandardCircuit.run(:flaky) { :ok }
        StandardCircuit.reset!
        name = runner.system_name

        3.times { StandardCircuit.reset! }

        expect(runner.system_name).to eq(name)
      end

      it "keeps a lock taken right after it (the reused system adopts the fresh Memory store)" do
        StandardCircuit.reset!
        runner.lock(:flaky, :open)

        expect(runner.circuit_state(:flaky)).to include(color: "red", locked: true)
      end
    end

    it "skips a generation name a host registered itself instead of raising" do
      configure_flaky
      StandardCircuit.run(:flaky) { :ok }
      current = runner.system_name[/_(\d+)\z/, 1]&.to_i || 1
      taken = [ current + 1, current + 2 ].map { |generation| "#{described_class::SYSTEM_NAME}_#{generation}" }
      taken.each { |name| Stoplight.register_system(name) }

      StandardCircuit.reset!

      expect(StandardCircuit.run(:flaky) { :ok }).to eq(:ok)
      expect(runner.system_name).to eq("#{described_class::SYSTEM_NAME}_#{current + 3}")
    end

    it "hands out each generation name once across threads" do
      names = Array.new(8) { Thread.new { Array.new(25) { described_class.next_system_name } } }.flat_map(&:value)

      expect(names.uniq.size).to eq(200)
    end

    it "starts at standard_circuit in a fresh process and moves to the next generation on rebuild" do
      output = run_in_fresh_process(<<~RUBY)
        require "standard_circuit"
        StandardCircuit.configure { |c| c.register(:x) }
        StandardCircuit.run(:x) { :ok }
        puts StandardCircuit.runner.system_name
        Stoplight.register_system("standard_circuit_3")
        StandardCircuit.reset!
        StandardCircuit.run(:x) { :ok }
        puts StandardCircuit.runner.system_name
      RUBY

      expect(output.lines.map(&:chomp).last(2)).to eq(%w[standard_circuit standard_circuit_2])
    end

    it "skips standard_circuit at boot when the host registered it first" do
      output = run_in_fresh_process(<<~RUBY)
        require "standard_circuit"
        Stoplight.register_system("standard_circuit")
        StandardCircuit.configure { |c| c.register(:x) }
        puts StandardCircuit.run(:x) { :ok }
        puts StandardCircuit.runner.system_name
      RUBY

      expect(output.lines.map(&:chomp).last(2)).to eq(%w[ok standard_circuit_2])
    end

    it "ignores the host's Stoplight.configure defaults" do
      output = run_in_fresh_process(<<~RUBY)
        require "standard_circuit"
        Stoplight.configure do |c|
          c.traffic_control, c.window_size, c.threshold, c.recovery_threshold = :error_rate, 300, 0.5, 5
        end
        StandardCircuit.configure { |c| c.register(:x, threshold: 1, tracked_errors: [RuntimeError]) }
        StandardCircuit.run(:x) { raise "boom" } rescue nil
        puts StandardCircuit.runner.light_for(:x).color
      RUBY

      # Under :error_rate (100-request minimum) one failure would never trip it.
      expect(output.lines.last.chomp).to eq("red")
    end
  end
end
