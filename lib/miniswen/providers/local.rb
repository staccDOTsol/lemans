# frozen_string_literal: true

require "ruby_llm"
require_relative "../local_route"

module Miniswen
  module Providers
    # Chat Completions against the operator's router. System messages stay
    # `system` — local servers reject OpenAI's `developer` role — and a reported
    # cost is kept instead of being rewritten to zero.
    module LocalChat
      def format_role(role) = role.to_s

      def reported_cost(usage)
        cost = usage["cost_usd"] || usage["cost"] || usage.dig("lemans", "cost_usd") || usage.dig("lecore", "cost_usd")
        return if cost.nil?
        raise ArgumentError unless cost.is_a?(Numeric)

        cost.to_f
      rescue ArgumentError, TypeError
        nil
      end
    end

    class Local < RubyLLM::Provider
      class ChatCompletions < RubyLLM::Protocols::ChatCompletions
        include LocalChat
      end

      protocol :chat_completions, ChatCompletions

      def api_base
        LocalRoute.endpoint!(@config.lemans_local_api_base)
      end

      def headers
        { "Authorization" => "Bearer #{LocalRoute.api_key(@config.lemans_local_api_key)}" }
      end

      class << self
        def local? = true

        def configuration_options
          %i[lemans_local_api_key lemans_local_api_base]
        end

        def configuration_requirements
          %i[lemans_local_api_base]
        end
      end
    end
  end
end

RubyLLM::Provider.register(:local, Miniswen::Providers::Local)
