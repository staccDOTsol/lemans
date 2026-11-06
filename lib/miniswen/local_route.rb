# frozen_string_literal: true

require "ipaddr"
require "json"
require "net/http"
require "uri"

module Miniswen
  # An OpenAI-compatible router on the operator's machine or LAN.
  # The base URL is always the one they set; there is no default host and no
  # hosted-model fallback. Identity comes from GET /models, and token totals
  # come from the completion body — missing fields stay unknown.
  module LocalRoute
    class Mismatch < StandardError; end

    DUMMY_KEY = "local-dummy"
    SHA_UNSET = "local checkpoint sha256 is unset (agent.local.checkpoint.sha256 or LEMANS_LOCAL_CHECKPOINT_SHA256)"
    BYTES_UNSET = "local checkpoint bytes are unset (agent.local.checkpoint.bytes or LEMANS_LOCAL_CHECKPOINT_BYTES)"
    UNSET_URL = "LEMANS_LOCAL_API_BASE must be set to the local router (no default endpoint)"
    IDENTITY = "expected checkpoint.sha256, checkpoint.bytes, and checkpoint.arm"

    CLOUD_LABELS = %w[openai deepseek openrouter anthropic googleapis azure].freeze
    LOCAL_SUFFIXES = %w[.local .lan .internal].freeze

    module_function

    def api_key(configured = nil)
      value = configured
      value = ENV["LEMANS_LOCAL_API_KEY"] if value.nil? || value.to_s.empty?
      value.to_s.empty? ? DUMMY_KEY : value.to_s
    end

    def endpoint!(url)
      raw = url.to_s.strip
      raise Mismatch, UNSET_URL if raw.empty?

      uri = URI.parse(raw)
      host = uri.host.to_s.downcase.delete_suffix(".")
      raise Mismatch, not_local(raw) unless %w[http https].include?(uri.scheme) && uri.userinfo.nil? && local_host?(host)

      path = uri.path.to_s.sub(%r{/+\z}, "")
      default_port = uri.scheme == "https" ? 443 : 80
      displayed = host.include?(":") ? "[#{host}]" : host
      origin = +"#{uri.scheme}://#{displayed}"
      origin << ":#{uri.port}" unless uri.port == default_port
      origin << path
      origin
    rescue URI::InvalidURIError
      raise Mismatch, not_local(raw)
    end

    def checkpoint_from_env
      sha = ENV["LEMANS_LOCAL_CHECKPOINT_SHA256"].to_s
      bytes = ENV["LEMANS_LOCAL_CHECKPOINT_BYTES"]
      return if sha.empty? && bytes.to_s.empty?

      normalize_checkpoint("sha256" => sha, "bytes" => bytes)
    end

    def normalize_checkpoint(checkpoint)
      checkpoint = {} unless checkpoint.is_a?(Hash)
      sha = value(checkpoint, "sha256").to_s
      bytes = value(checkpoint, "bytes")
      raise Mismatch, SHA_UNSET if sha.empty?
      raise Mismatch, "local checkpoint sha256 #{sha.inspect} is not 64 hex characters" unless sha.match?(/\A[0-9a-f]{64}\z/i)
      raise Mismatch, BYTES_UNSET if bytes.nil? || bytes.to_s.empty?

      count = Integer(bytes)
      raise Mismatch, "local checkpoint bytes must be positive, got #{count}" unless count.positive?

      { sha256: sha.downcase, bytes: count }
    rescue ArgumentError, TypeError
      raise Mismatch, "local checkpoint bytes must be a positive integer, got #{bytes.inspect}"
    end

    # `fetch` replaces the GET when a caller already holds the model list.
    # It is not a fallback: a missing or mismatched checkpoint still raises.
    def verify!(model_ids:, checkpoint: nil, base: nil, fetch: nil)
      ids = Array(model_ids).map { model_id(it) }.uniq
      raise Mismatch, "local arm model ids are unset" if ids.empty?

      expected = normalize_checkpoint(checkpoint || checkpoint_from_env)
      url = endpoint!(base || RubyLLM.config.lemans_local_api_base || ENV["LEMANS_LOCAL_API_BASE"])
      key = api_key(RubyLLM.config.lemans_local_api_key)
      payload = (fetch || method(:fetch_models)).call(url, key)
      models = index_models(payload)
      ids.each { |id| assert_identity!(models, id, expected) }
      url
    end

    def model_id(name)
      bare = name.to_s.split("#", 2).first
      provider, id = bare.split("/", 2)
      provider == "local" && id ? id : bare
    end

    def fetch_models(base, key)
      get_json("#{base}/models", key)
    end

    # Visible OpenAI usage, overridden by a `lemans` object (or `lecore` when
    # `lemans` is absent). Absent keys stay nil — they are not zeroes.
    def account(body)
      body = {} unless body.is_a?(Hash)
      usage = hash_field(body, "usage")
      lemans = hash_field(body, "lemans")
      lecore = hash_field(body, "lecore")
      ext = present?(body, "lemans") ? lemans : lecore
      reported, reasoning = reasoning_from(usage, ext)
      {
        prompt_tokens: first_count(ext, usage, "prompt_tokens"),
        generated_tokens: generated_tokens(ext, usage),
        reasoning_tokens: reasoning,
        reasoning_reported: reported,
        model_requests: model_requests(ext, lecore),
        phases: phases_from(ext, lecore),
        phases_reported: present?(ext, "phases") || present?(lecore, "phases"),
        cost_usd: first_amount(ext, usage),
        cost_reported: cost_reported?(ext, usage),
        usage_present: present?(body, "usage") || present?(body, "lemans") || present?(body, "lecore")
      }
    end

    def merge_phases(left, right)
      return if left.nil? || right.nil?

      names = (left + right).map { phase_name(it) }.uniq
      names.map { |name| merged_phase(name, left, right) }
    end

    def not_local(url) = "LEMANS_LOCAL_API_BASE #{url.inspect} is not a local or LAN URL"

    def local_host?(host)
      return false if host.empty? || cloud_host?(host)
      return true if host == "localhost" || host.end_with?(*LOCAL_SUFFIXES)
      return true if !host.include?(".") && host.match?(/\A[a-z0-9-]+\z/i)

      ip_local?(host)
    end

    def cloud_host?(host)
      CLOUD_LABELS.intersect?(host.split("."))
    end

    def ip_local?(host)
      ip = IPAddr.new(host)
      ip.loopback? || ip.private? || ip.link_local?
    rescue IPAddr::InvalidAddressError
      false
    end

    def index_models(payload)
      rows = payload.is_a?(Hash) ? value(payload, "data") : payload
      raise Mismatch, "the router model list is not an OpenAI models object" unless rows.is_a?(Array)

      rows.to_h { |row| [ value(row, "id").to_s, row ] }
    end

    def assert_identity!(models, id, expected)
      row = models[id] or raise Mismatch, "local model #{id.inspect} is not in the router model list"
      identity = identity_of(row, id)
      unless identity[:sha256] == expected[:sha256]
        raise Mismatch, "local model #{id.inspect} checkpoint sha256 #{identity[:sha256]} does not match #{expected[:sha256]}"
      end
      return if identity[:bytes] == expected[:bytes]

      raise Mismatch, "local model #{id.inspect} checkpoint is #{identity[:bytes]} bytes, expected #{expected[:bytes]}"
    end

    def identity_of(row, id)
      checkpoint = value(row, "checkpoint")
      unless checkpoint.is_a?(Hash) && identity_complete?(checkpoint)
        raise Mismatch, "local model #{id.inspect} does not identify a checkpoint (#{IDENTITY})"
      end

      arm = value(checkpoint, "arm").to_s
      raise Mismatch, "local model #{id.inspect} is arm #{arm.inspect}, expected #{id.inspect}" unless arm == id

      { sha256: value(checkpoint, "sha256").to_s.downcase, bytes: value(checkpoint, "bytes"), arm: }
    end

    def identity_complete?(checkpoint)
      value(checkpoint, "sha256").to_s.match?(/\A[0-9a-f]{64}\z/i) &&
        value(checkpoint, "bytes").is_a?(Integer) && value(checkpoint, "bytes").positive? &&
        !value(checkpoint, "arm").to_s.empty?
    end

    def get_json(url, key)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 5
      http.read_timeout = 5
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{key}"
      response = http.request(request)
      raise Mismatch, "the local router redirected #{uri.host}; refusing to follow" if response.is_a?(Net::HTTPRedirection)
      raise Mismatch, "GET #{uri.host}#{uri.path} returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue Mismatch
      raise
    rescue StandardError => e
      raise Mismatch, "the local router at #{URI(url).host} did not answer (#{e.class})"
    end

    def reasoning_from(usage, ext)
      return [ true, count_field(ext, "reasoning_tokens") ] if present?(ext, "reasoning_tokens")

      details = hash_field(usage, "completion_tokens_details")
      return [ true, count_field(details, "reasoning_tokens") ] if present?(details, "reasoning_tokens")
      return [ true, count_field(usage, "reasoning_tokens") ] if present?(usage, "reasoning_tokens")

      [ false, nil ]
    end

    def generated_tokens(ext, usage)
      return count_field(ext, "generated_tokens") if present?(ext, "generated_tokens")
      return count_field(usage, "completion_tokens") if present?(usage, "completion_tokens")

      nil
    end

    def model_requests(ext, lecore)
      return count_field(ext, "model_requests") if present?(ext, "model_requests")
      return count_field(ext, "requests") if present?(ext, "requests")
      return count_field(lecore, "requests") if present?(lecore, "requests")

      nil
    end

    def phases_from(ext, lecore)
      source = if present?(ext, "phases")
        ext
      elsif present?(lecore, "phases")
        lecore
      end
      return unless source

      normalize_phases(value(source, "phases"))
    end

    def normalize_phases(phases)
      raise AccountingError, "leCore phases must be a list" unless phases.is_a?(Array)

      phases.map { |phase| normalize_phase(phase) }
    end

    def normalize_phase(phase)
      raise AccountingError, "a leCore phase needs a name and a duration" unless phase.is_a?(Hash)

      name = value(phase, "name").to_s
      duration = value(phase, "duration")
      raise AccountingError, "a leCore phase needs a name and a duration" if name.empty? || !duration.is_a?(Numeric)

      entry = { name:, duration: duration.to_f }
      tokens = value(phase, "tokens")
      entry[:tokens] = count(tokens, "phase.tokens") unless tokens.nil?
      entry
    end

    def merged_phase(name, left, right)
      parts = [ left, right ].filter_map { |list| list.find { phase_name(it) == name } }
      entry = { name:, duration: parts.sum { phase_duration(it) }.round(3) }
      entry[:tokens] = parts.sum { phase_tokens(it) } if parts.all? { phase_has_tokens?(it) }
      entry
    end

    def first_count(ext, usage, key)
      return count_field(ext, key) if present?(ext, key)
      return count_field(usage, key) if present?(usage, key)

      nil
    end

    def first_amount(ext, usage)
      return amount(value(ext, "cost_usd"), "cost_usd") if present?(ext, "cost_usd")
      return amount(value(usage, "cost_usd"), "cost_usd") if present?(usage, "cost_usd")
      return amount(value(usage, "cost"), "cost") if present?(usage, "cost")

      nil
    end

    def cost_reported?(ext, usage)
      present?(ext, "cost_usd") || present?(usage, "cost_usd") || present?(usage, "cost")
    end

    def count_field(hash, key)
      raw = value(hash, key)
      raw.nil? ? nil : count(raw, key)
    end

    def count(value, key)
      raise AccountingError, "local usage #{key} must be a non-negative integer, got #{value.inspect}" unless value.is_a?(Integer) && value >= 0

      value
    end

    def amount(value, key)
      return if value.nil?
      raise AccountingError, "local usage #{key} must be a number, got #{value.inspect}" unless value.is_a?(Numeric)

      value.to_f
    end

    def hash_field(hash, key)
      raw = value(hash, key)
      raw.is_a?(Hash) ? raw : {}
    end

    def present?(hash, key) = hash.is_a?(Hash) && (hash.key?(key) || hash.key?(key.to_sym))

    def value(hash, key)
      return unless hash.is_a?(Hash)
      return hash[key] if hash.key?(key)

      hash[key.to_sym] if hash.key?(key.to_sym)
    end

    def phase_name(phase) = (phase[:name] || phase["name"]).to_s

    def phase_duration(phase) = (phase[:duration] || phase["duration"]).to_f

    def phase_has_tokens?(phase) = phase.key?(:tokens) || phase.key?("tokens")

    def phase_tokens(phase) = phase[:tokens] || phase["tokens"]
  end
end
