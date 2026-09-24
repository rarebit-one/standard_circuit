class ProbeMailer < ActionMailer::Base
  default from: "probe@example.com"

  def hello
    mail(to: "someone@example.com", subject: "hello", body: "hello")
  end
end
