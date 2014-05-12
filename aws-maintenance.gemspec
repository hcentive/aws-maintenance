# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'aws/version'

Gem::Specification.new do |spec|
  spec.name          = "aws-maintenance"
  spec.version       = Aws::VERSION
  spec.authors       = ["Satyendra Sharma"]
  spec.email         = ["satyendra.sharma@hcentive.com"]
  spec.summary       = "AWS Maintenance Utility"
  spec.description   = "Provides methods to maintain AWS instances"
  spec.homepage      = ""
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency 'safe_yaml', "~> 1.0"
  spec.add_runtime_dependency "aws-sdk-core", "~> 2.0"

  spec.add_development_dependency "bundler", "~> 1.5"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "rspec"
end
