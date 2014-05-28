require 'simplecov'

SimpleCov.formatter = SimpleCov::Formatter::MultiFormatter[
  SimpleCov::Formatter::HTMLFormatter,
#  Coveralls::SimpleCov::Formatter
]
SimpleCov.start do
  add_filter '.bundle/'
  add_filter '_spec.rb$'
end
