# Boots a real (minimal, lazily-loaded unless eager) Rails application with
# `mailer_retry` enabled from `to_prepare`, as every consumer does, then touches
# the mail/job constants in the order PROBE_ORDER names. In a lazily-loaded
# process the first constant touched decides which class loads ActiveJob::Base,
# and 0.4.0 raised NameError whenever that was ActionMailer::MailDeliveryJob's
# own `class MailDeliveryJob < ActiveJob::Base`.
#
# Run as a subprocess by spec/integration/mailer_retry_load_order_spec.rb: load
# order is process-global and can't be reset in the spec process.
#
# PROBE_ORDER:
#   mailer_first   — ActionMailer::Base first (a dev `deliver_later`; the reported crash)
#   job_first      — ActionMailer::MailDeliveryJob first (a worker deserializing
#                    the job before any mailer has loaded), then performs it
#   subclass_first — a custom delivery_job subclass with its own rescue_from first
#   active_job_first — ActiveJob::Base first (0.4.0 worked here)
#   eager          — config.eager_load = true (production shape)
#
# Prints `key=value` lines for the spec to assert on.
ORDER = ENV.fetch("PROBE_ORDER")
require "rails"
require "action_mailer/railtie"
require "active_job/railtie"
require "standard_circuit"

class MailerRetryLoadOrderApp < Rails::Application
  config.root = File.expand_path("mailer_retry_load_order_app_root", __dir__)
  config.eager_load = ORDER == "eager"
  config.load_defaults 8.0
  config.secret_key_base = "x" * 64
  config.logger = Logger.new(IO::NULL)
  config.active_job.queue_adapter = :test
  config.action_mailer.delivery_method = :test

  config.to_prepare do
    StandardCircuit.configure { |c| c.mailer_retry = { jitter: 0.0 } }
  end
end

MailerRetryLoadOrderApp.initialize!

def installed?(job_class) = StandardCircuit::Mailer::Retry.installed?(job_class)

puts "active_job_loaded_at_boot=#{ActiveJob.autoload?(:Base).nil?}"

begin
  case ORDER
  when "mailer_first"
    ActionMailer::Base
    ProbeMailer.hello.deliver_later
    puts "enqueued=#{ActiveJob::Base.queue_adapter.enqueued_jobs.size}"
  when "job_first"
    ActionMailer::MailDeliveryJob
    puts "action_mailer_loaded_before_perform=#{ActionMailer.autoload?(:Base).nil?}"
    # The mail circuit is open for this delivery.
    ActionMailer::Base.add_delivery_method(:circuit_open, Class.new {
      def initialize(*) = nil
      def deliver!(mail) = raise(StandardCircuit::Mailer::CircuitOpenError.new(recipients: mail.to, subject: mail.subject))
    })
    ActionMailer::Base.delivery_method = :circuit_open
    ActionMailer::MailDeliveryJob.perform_now("ProbeMailer", "hello", "deliver_now", args: [])
    retried = ActiveJob::Base.queue_adapter.enqueued_jobs
    puts "retried=#{retried.size == 1 && retried.first[:job] == ActionMailer::MailDeliveryJob}"
  when "subclass_first"
    CustomDeliveryJob
    puts "action_mailer_loaded=#{ActionMailer.autoload?(:Base).nil?}"
    puts "subclass_installed=#{installed?(CustomDeliveryJob)}"
    names = CustomDeliveryJob.rescue_handlers.map(&:first)
    # Handlers are tried last-first: the subclass's own must still win.
    puts "subclass_handler_order=#{names.last(2).join(',')}"
  when "active_job_first"
    ActiveJob::Base
  when "eager"
    nil
  end
  puts "error=none"
rescue NameError => e
  puts "error=#{e.class}: #{e.message.lines.first.chomp}"
end

ActionMailer::Base
puts "installed=#{installed?(ActionMailer::MailDeliveryJob)}"
puts "handlers=#{ActionMailer::MailDeliveryJob.rescue_handlers.count { |(name, _)| name == StandardCircuit::Mailer::CircuitOpenError.name }}"
