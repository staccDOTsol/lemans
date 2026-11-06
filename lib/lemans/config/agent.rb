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
          read_local!(conf, data["local"]) if data.key?("local")

          conf
        rescue KeyError => e
          raise ConfigError, "agent.#{e.key} must be provided"
        end

        private

        def read_local!(conf, data)
          raise ConfigError, "agent.local must be a mapping" unless data.is_a?(Hash)

          conf.local_checkpoint = checkpoint!(data)
          conf.local_dsml = dsml!(data["dsml"]) if data.key?("dsml")
          conf.local_bash_call_limit = bash_limit!(data["bash_call_limit"]) if data.key?("bash_call_limit")
        end

        def checkpoint!(data)
          raise ConfigError, "agent.local.checkpoint must be provided" unless data["checkpoint"].is_a?(Hash)

          Miniswen::LocalRoute.normalize_checkpoint(data["checkpoint"])
        rescue Miniswen::LocalRoute::Mismatch => e
          raise ConfigError, e.message
        end

        def dsml!(value)
          return value if value == true || value == false

          raise ConfigError, "agent.local.dsml must be true or false"
        end

        def bash_limit!(value)
          limit = integer!(value)
          raise ConfigError, "agent.local.bash_call_limit must be non-negative, got #{limit}" if limit.negative?

          limit
        end
      end

      attr_accessor :name, :models, :timeout,
                    :step_limit, :cost_limit, :exec_timeout, :max_output_tokens,
                    :environment, :local_checkpoint, :local_dsml, :local_bash_call_limit

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
          "local" => local_to_h
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
        @local_dsml = false
        @local_bash_call_limit = nil
      end

      def local_to_h
        return unless local_checkpoint || local_dsml || !local_bash_call_limit.nil?

        {
          "checkpoint" => ({ "sha256" => local_checkpoint[:sha256], "bytes" => local_checkpoint[:bytes] } if local_checkpoint),
          "dsml" => (true if local_dsml),
          "bash_call_limit" => local_bash_call_limit
        }.compact
      end
    end
  end
end
