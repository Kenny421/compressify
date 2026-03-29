# frozen_string_literal: true

require "rails/railtie"

module Compressify
  class Railtie < Rails::Railtie
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
