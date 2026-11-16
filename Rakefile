# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "rb_sys/extensiontask"

task build: :compile

GEMSPEC = Gem::Specification.load("say_when_rb.gemspec")

RbSys::ExtensionTask.new("say_when", GEMSPEC) do |ext|
  ext.lib_dir = "lib/say_when"
end

task default: %i[compile spec]
