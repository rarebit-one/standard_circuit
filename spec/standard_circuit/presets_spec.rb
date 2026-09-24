require "spec_helper"
require "aws-sdk-s3"
require "postmark"

RSpec.describe StandardCircuit::Presets do
  # Exercised through the public entry point, Config#register_preset.
  let(:config) { StandardCircuit::Config.new }

  describe ":postmark" do
    it "registers a named :postmark circuit with the settings the host apps hand-rolled" do
      spec = config.register_preset(:postmark)

      expect(config.circuits[:postmark]).to be(spec)
      expect(spec).to have_attributes(
        threshold: 3,
        cool_off_time: 60,
        criticality: :standard,
        tracked_errors: StandardCircuit::NetworkErrors.defaults + [ Postmark::HttpServerError, Postmark::TimeoutError ],
        skipped_errors: [ Postmark::ApiInputError, Postmark::InvalidApiKeyError ]
      )
    end

    it "lets explicit options win over the preset" do
      spec = config.register_preset(:postmark, criticality: :critical, skipped_errors: [])
      expect(spec.criticality).to eq(:critical)
      expect(spec.skipped_errors).to eq([])
      expect(spec.cool_off_time).to eq(60)
    end

    it "registers under a custom name" do
      config.register_preset(:postmark, name: :transactional_mail)
      expect(config.circuits.keys).to eq([ :transactional_mail ])
    end

    it "raises a clear error when the postmark gem can't be loaded" do
      hide_const("Postmark")
      allow(described_class).to receive(:require).with("postmark").and_raise(LoadError)

      expect { config.register_preset(:postmark) }
        .to raise_error(ArgumentError, /needs the postmark gem/)
    end
  end

  describe ":s3" do
    it "registers an s3 prefix with the AWS taxonomy and the default caller-error skips" do
      spec = config.register_preset(:s3)

      expect(config.prefixes["s3"]).to be(spec)
      expect(config.spec_for(:s3_my_bucket)).to be(spec)
      expect(spec).to have_attributes(
        threshold: 3,
        cool_off_time: 30,
        criticality: :standard,
        tracked_errors: StandardCircuit::ErrorTaxonomies::Aws.tracked
      )
      expect(spec.skipped_errors).to contain_exactly(Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::AccessDenied)
    end

    it "requires aws-sdk-s3 when it hasn't been loaded yet (Gemfile require: false)" do
      hide_const("Aws")
      allow(described_class).to receive(:require).with("aws-sdk-s3").and_raise(LoadError)

      expect { config.register_preset(:s3) }.to raise_error(ArgumentError, /needs the aws-sdk-s3 gem/)
      expect(described_class).to have_received(:require).with("aws-sdk-s3")
    end
  end

  it "rejects unknown presets" do
    expect { config.register_preset(:stripe) }
      .to raise_error(ArgumentError, /unknown preset :stripe; available: \[:postmark, :s3\]/)
  end
end
