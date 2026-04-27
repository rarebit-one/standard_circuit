require "spec_helper"
require "fileutils"
require "stringio"
require "rails/generators"
require "generators/standard_circuit/install/install_generator"

RSpec.describe StandardCircuit::Generators::InstallGenerator, type: :generator do
  let(:destination_root) { File.expand_path("../../../tmp/generator_dest", __dir__) }
  let(:initializer_path) { File.join(destination_root, "config/initializers/standard_circuit.rb") }
  let(:health_initializer_path) { File.join(destination_root, "config/initializers/standard_circuit_health.rb") }

  before do
    FileUtils.rm_rf(destination_root)
    FileUtils.mkdir_p(File.join(destination_root, "config/initializers"))
  end

  after do
    FileUtils.rm_rf(destination_root)
  end

  def run_generator(args = [])
    captured = StringIO.new
    original_stdout = $stdout
    $stdout = captured
    described_class.start(args, destination_root: destination_root)
    captured.string
  ensure
    $stdout = original_stdout
  end

  describe "default invocation" do
    it "creates the initializer file" do
      run_generator
      expect(File).to exist(initializer_path)
    end

    it "templates the configure block and DSL examples into the initializer" do
      run_generator
      content = File.read(initializer_path)

      expect(content).to include("StandardCircuit.configure do |config|")
      expect(content).to include("config.register(:stripe,")
      expect(content).to include("config.register_prefix(:s3,")
      expect(content).to include("StandardCircuit::ErrorTaxonomies::Stripe.tracked")
      expect(content).to include("config.extra_notifiers")
    end

    it "does not create the health initializer" do
      run_generator
      expect(File).not_to exist(health_initializer_path)
    end

    it "does not print the health route hint" do
      output = run_generator
      expect(output).not_to include("get \"/health\"")
    end
  end

  describe "idempotency" do
    it "skips when the initializer already exists" do
      run_generator
      sentinel = "# user customisation\n"
      File.write(initializer_path, sentinel)

      output = run_generator

      expect(output).to match(/already present, skipping/)
      expect(File.read(initializer_path)).to eq(sentinel)
    end
  end

  describe "--force" do
    it "overwrites an existing initializer" do
      File.write(initializer_path, "# stale\n")

      run_generator([ "--force" ])

      content = File.read(initializer_path)
      expect(content).to include("StandardCircuit.configure do |config|")
      expect(content).not_to eq("# stale\n")
    end
  end

  describe "--with-health-endpoint" do
    it "creates the health initializer that requires the controller" do
      run_generator([ "--with-health-endpoint" ])

      expect(File).to exist(health_initializer_path)
      content = File.read(health_initializer_path)
      expect(content).to include('require "standard_circuit/health_controller"')
    end

    it "prints the route hint without modifying routes.rb" do
      output = run_generator([ "--with-health-endpoint" ])

      expect(output).to include('get "/health", to: "standard_circuit/health#show"')
      expect(output).to include("StandardCircuit health endpoint installed.")
    end

    it "still creates the main initializer" do
      run_generator([ "--with-health-endpoint" ])
      expect(File).to exist(initializer_path)
    end

    it "skips the health initializer when it already exists without --force" do
      run_generator([ "--with-health-endpoint" ])
      sentinel = "# user customisation\n"
      File.write(health_initializer_path, sentinel)

      output = run_generator([ "--with-health-endpoint" ])

      expect(output).to match(/already present, skipping/)
      expect(File.read(health_initializer_path)).to eq(sentinel)
    end

    it "overwrites the health initializer when --force is passed" do
      run_generator([ "--with-health-endpoint" ])
      sentinel = "# user customisation\n"
      File.write(health_initializer_path, sentinel)

      output = run_generator([ "--with-health-endpoint", "--force" ])

      expect(File.read(health_initializer_path)).to include('require "standard_circuit/health_controller"')
      expect(output).to include('get "/health", to: "standard_circuit/health#show"')
    end
  end
end
