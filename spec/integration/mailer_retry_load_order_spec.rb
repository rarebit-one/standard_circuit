require "spec_helper"
require "open3"

# 0.4.0 installed mailer_retry from `on_load(:active_job)` and referenced
# ActionMailer::MailDeliveryJob inside the hook. When MailDeliveryJob's own
# `class MailDeliveryJob < ActiveJob::Base` was what loaded ActiveJob::Base, the
# hook ran mid-autoload and raised NameError: the first `deliver_later` in a
# fresh development process crashed, and so did `bin/tapioca dsl`. Load order
# is process-global, so each order boots its own Rails app in a subprocess.
module MailerRetryLoadOrderProbe
  SCRIPT = File.expand_path("../support/mailer_retry_load_order_app.rb", __dir__)

  def self.boot(order)
    (@boots ||= {})[order] ||= begin
      stdout, stderr, status = Open3.capture3({ "PROBE_ORDER" => order }, RbConfig.ruby, SCRIPT)
      raise "probe app (#{order}) failed (#{status.exitstatus}):\n#{stdout}\n#{stderr}" unless status.success?

      stdout.lines.filter_map { |line| line.chomp.split("=", 2) if line.include?("=") }.to_h
    end
  end
end

RSpec.describe "mailer_retry installation across load orders" do
  let(:boot) { MailerRetryLoadOrderProbe.boot(order) }

  shared_examples "installs the retry exactly once without crashing" do
    it "loads without NameError" do
      expect(boot["error"]).to eq("none")
    end

    it "installs one CircuitOpenError handler on ActionMailer::MailDeliveryJob" do
      expect(boot["installed"]).to eq("true")
      expect(boot["handlers"]).to eq("1")
    end
  end

  context "when a mailer is the first thing loaded (dev deliver_later — the reported crash)" do
    let(:order) { "mailer_first" }

    it_behaves_like "installs the retry exactly once without crashing"

    it "boots without loading ActiveJob::Base, so MailDeliveryJob is what loads it" do
      expect(boot["active_job_loaded_at_boot"]).to eq("false")
    end

    it "enqueues the delivery" do
      expect(boot["enqueued"]).to eq("1")
    end
  end

  context "when a worker deserializes MailDeliveryJob before any mailer has loaded" do
    let(:order) { "job_first" }

    it_behaves_like "installs the retry exactly once without crashing"

    it "retries a delivery that hits an open mail circuit" do
      expect(boot["action_mailer_loaded_before_perform"]).to eq("false")
      expect(boot["retried"]).to eq("true")
    end
  end

  context "when a custom delivery_job subclass with its own rescue_from loads first" do
    let(:order) { "subclass_first" }

    it_behaves_like "installs the retry exactly once without crashing"

    it "gives the subclass the handler before any mailer loads" do
      expect(boot["action_mailer_loaded"]).to eq("false")
      expect(boot["subclass_installed"]).to eq("true")
    end

    it "keeps the subclass's own handlers ahead of the inherited one" do
      expect(boot["subclass_handler_order"]).to eq("StandardCircuit::Mailer::CircuitOpenError,ArgumentError")
    end
  end

  context "when ActiveJob::Base loads first" do
    let(:order) { "active_job_first" }

    it_behaves_like "installs the retry exactly once without crashing"
  end

  context "with eager loading (production shape)" do
    let(:order) { "eager" }

    it_behaves_like "installs the retry exactly once without crashing"
  end
end
