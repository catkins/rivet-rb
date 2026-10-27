require "bundler/gem_tasks"
require "rb_sys/extensiontask"
require "rake/testtask"

RbSys::ExtensionTask.new("rivet_native", Gem::Specification.load("rivet.gemspec")) do |ext|
  ext.ext_dir = "ext/rivet"
  ext.lib_dir = "lib/rivet"
end

Rake::TestTask.new(:test) do |test|
  test.libs << "test"
  test.pattern = "test/*_test.rb"
end

task default: [:compile, :test]
