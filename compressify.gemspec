# frozen_string_literal: true

require_relative "lib/compressify/version"

Gem::Specification.new do |spec|
  spec.name          = "compressify"
  spec.version       = Compressify::VERSION
  spec.authors       = ["Kenroy Reid"]
  spec.email         = [""]

  spec.summary       = "Automatic Active Storage compression for Rails."
  spec.description   = "Compressify reduces Active Storage storage costs by compressing uploaded images with libvips and optionally transcoding videos with ffmpeg in background jobs."
  spec.homepage      = "https://github.com/Kenny421/compressify"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = spec.homepage + "/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    Dir["{bin,lib}/**/*", "LICENSE.txt", "README.md", "CHANGELOG.md"]
  end
  spec.bindir = "bin"
  spec.require_paths = ["lib"]

  spec.add_dependency "activesupport", ">= 6.1"
  spec.add_dependency "activejob", ">= 6.1"
  spec.add_dependency "activestorage", ">= 6.1"
  spec.add_dependency "image_processing", ">= 1.12"
  spec.add_dependency "ruby-vips", ">= 2.2"

  spec.add_development_dependency "rake", ">= 13.0"
  spec.add_development_dependency "minitest", ">= 5.0"
end
