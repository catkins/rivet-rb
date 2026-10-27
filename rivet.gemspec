require_relative "lib/rivet/version"

Gem::Specification.new do |spec|
  spec.name = "rivet"
  spec.version = Rivet::VERSION
  spec.authors = ["Chris Atkins"]
  spec.summary = "Ruby actors and clients powered by the RivetKit Rust runtime"
  spec.homepage = "https://github.com/catkins/rivet-rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir[
    "lib/**/*.rb",
    "ext/**/*.{rs,rb,toml}",
    "Cargo.{toml,lock}",
    "README.md",
    "RESEARCH.md",
    "LICENSE"
  ]
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/rivet/extconf.rb"]
  spec.add_dependency "rb_sys", "~> 0.9"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rake-compiler", "~> 1.3"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "aws-sdk-s3", "~> 1.0"
end
