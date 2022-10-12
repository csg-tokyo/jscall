# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  files = FileList["test/**/test_*.rb"]
  unless /linux/ =~ RbConfig::CONFIG['host_os']
    files.exclude "test/test_sync_io.rb"
  end
  t.test_files = files
end

task default: :test
# task default: %i[]
