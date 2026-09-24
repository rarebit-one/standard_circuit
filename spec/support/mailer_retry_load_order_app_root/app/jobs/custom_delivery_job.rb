# A host's `self.delivery_job = CustomDeliveryJob` with rescue handlers of its
# own, so it holds its own copy of rescue_handlers rather than reading the
# parent's.
class CustomDeliveryJob < ActionMailer::MailDeliveryJob
  rescue_from ArgumentError, with: :handle_argument_error

  private

  def handle_argument_error(_error) = nil
end
