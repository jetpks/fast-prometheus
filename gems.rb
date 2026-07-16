# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :test do
  gem "sus"
  gem "sus-fixtures-async"
  gem "covered"
  gem "rubocop"
end
