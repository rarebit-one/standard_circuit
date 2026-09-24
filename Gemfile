source "https://rubygems.org"

gemspec

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "rubocop", require: false
  gem "rubocop-rails-omakase", require: false
  gem "rubocop-rspec", require: false
end

group :test do
  gem "aws-sdk-s3", require: false
  gem "stripe", require: false
  gem "faraday", require: false
  gem "postmark", require: false
  gem "activestorage", ">= 8.1", require: false
end
