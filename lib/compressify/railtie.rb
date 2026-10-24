# frozen_string_literal: true

require "rails/railtie"

module Compressify
  class Railtie < Rails::Railtie
    rake_tasks do
      load File.expand_path("../tasks/compressify.rake", __dir__)
    end

    initializer "compressify.include_concerns" do
      ActiveSupport.on_load(:action_controller) do
        include Compressify::Controller
      end

      ActiveSupport.on_load(:active_record) do
        include Compressify::Model
      end
    end
  end
end
