# frozen_string_literal: true

require "rails/generators"

module Compressify
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates a Compressify initializer."

      def copy_initializer
        template "compressify.rb", "config/initializers/compressify.rb"
      end
    end
  end
end
