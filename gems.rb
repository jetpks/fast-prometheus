# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :test do
  gem "sus"
  gem "sus-fixtures-async"
  gem "sus-fixtures-async-http"
  gem "covered"
  gem "rubocop"
end
