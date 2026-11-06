# frozen_string_literal: true

module Lemans
  class Config
    class Agent # :nodoc:
      class << self
        include Conversion

        def from_config(data)
          return if data.nil?

          name = data.fetch("name")
          model = data.fetch("model")

          conf = new(name, model)

          conf.step_limit = integer!(data["step_limit"]) if data["step_limit"]
          conf.cost_limit = float!(data["cost_limit"]) if data["cost_limit"]
          conf.timeout = seconds!(data["timeout"]) if data["timeout"]
          conf.exec_timeout = seconds!(data["exec_timeout"]) if data["exec_timeout"]
          conf.max_output_tokens = integer!(data["max_output_tokens"]) if data.key?("max_output_tokens")

          if (network_data = data.dig("environment", "network"))
            conf.environment = Environment.new(network: NetworkPolicy.from_config(network_data))
          end
          conf.local_checkpoint = checkpoint!(data["local"]) if data.key?("local")

          conf
        rescue KeyError => e
          raise ConfigError, "agent.#{e.key} must be provided"
        end

        private

        def checkpoint!(data)
          raise ConfigError, "agent.local must be a mapping" unless data.is_a?(Hash)
          raise ConfigError, "agent.local.checkpoint must be provided" unless data["checkpoint"].is_a?(Hash)

          Miniswen::LocalRoute.normalize_checkpoint(data["checkpoint"])
        rescue Miniswen::LocalRoute::Mismatch => e
          raise ConfigError, e.message
        end
      end

      attr_accessor :name, :models, :timeout,
                    :step_limit, :cost_limit, :exec_timeout, :max_output_tokens,
                    :environment, :local_checkpoint

      def model = models.first

      def to_h
        {
          "name" => name,
          "model" => models,
          "timeout" => timeout,
          "step_limit" => step_limit,
          "cost_limit" => cost_limit,
          "exec_timeout" => exec_timeout,
          "max_output_tokens" => max_output_tokens,
          "environment" => { "network" => environment.network.to_h },
          "local" => ({ "checkpoint" => { "sha256" => local_checkpoint[:sha256], "bytes" => local_checkpoint[:bytes] } } if local_checkpoint)
        }.compact
      end

      Environment = Struct.new(:network, keyword_init: true)

      def initialize(name, model)
        @name = name
        @models = Array(model)
        @step_limit = 100
        @cost_limit = nil
        @exec_timeout = 300
        @max_output_tokens = 0
        @timeout = 30 * 60
        @environment = Environment.new(network: NetworkPolicy.new)
        @local_checkpoint = nil
      end
    end
  end
end
