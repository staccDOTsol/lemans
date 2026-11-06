# frozen_string_literal: true

require "test_helper"

require "miniswen/testing"

class LocalRouteTest < Minitest::Test
  include Miniswen::Testing

  SHA = "e8289c0026d746197d5f9b865b0b87c4a16dc94430d9cfed4a11074bf05ea36e"
  BYTES = 103_425_694_816

  class RecordingEnv < Miniswen::Testing::FakeEnv
    attr_reader :envs

    def exec(command, timeout: nil, env: nil)
      (@envs ||= []) << env
      super
    end
  end

  def setup
    @base = RubyLLM.config.lemans_local_api_base
    @key = RubyLLM.config.lemans_local_api_key
    RubyLLM.configure { it.lemans_local_api_base = "http://127.0.0.1:9/v1" }
  end

  def teardown
    RubyLLM.configure do |config|
      config.lemans_local_api_base = @base
      config.lemans_local_api_key = @key
    end
  end

  def test_endpoint_identity_and_usage
    assert_equal "http://127.0.0.1:9/v1", Miniswen::LocalRoute.endpoint!("http://127.0.0.1:9/v1/")
    assert_equal "http://192.168.1.10:8080/v1", Miniswen::LocalRoute.endpoint!("http://192.168.1.10:8080/v1")
    assert_equal "http://asus:8080/v1", Miniswen::LocalRoute.endpoint!("http://asus:8080/v1")
    assert_equal "http://router.local/v1", Miniswen::LocalRoute.endpoint!("http://router.local/v1")

    [ nil, "  ", "https://api.deepseek.com/v1", "http://8.8.8.8/v1", "http://deepseek.local/v1" ].each do |url|
      error = assert_raises(Miniswen::LocalRoute::Mismatch) { Miniswen::LocalRoute.endpoint!(url) }
      if url.nil? || url.strip.empty?
        assert_equal "LEMANS_LOCAL_API_BASE must be set to the local router (no default endpoint)", error.message
      else
        assert_equal "LEMANS_LOCAL_API_BASE #{url.inspect} is not a local or LAN URL", error.message
      end
    end

    called = false
    error = assert_raises(Miniswen::LocalRoute::Mismatch) do
      Miniswen::LocalRoute.verify!(model_ids: [ "direct" ], checkpoint: { sha256: SHA, bytes: BYTES },
                                  base: "https://api.openai.com/v1", fetch: ->(*) { called = true })
    end

    refute called
    assert_includes error.message, "not a local or LAN URL"

    error = assert_raises(Miniswen::LocalRoute::Mismatch) do
      Miniswen::LocalRoute.verify!(model_ids: %w[direct lecore], checkpoint: { sha256: SHA, bytes: BYTES },
                                  fetch: ->(*) { { "data" => [ row("direct"), row("lecore", bytes: 1) ] } })
    end

    assert_equal "local model \"lecore\" checkpoint is 1 bytes, expected #{BYTES}", error.message

    error = assert_raises(Miniswen::LocalRoute::Mismatch) do
      Miniswen::LocalRoute.verify!(model_ids: %w[direct lecore], checkpoint: { sha256: SHA, bytes: BYTES },
                                  fetch: ->(*) { { "data" => [ row("direct") ] } })
    end

    assert_equal "local model \"lecore\" is not in the router model list", error.message

    bare = { "id" => "direct" }
    error = assert_raises(Miniswen::LocalRoute::Mismatch) do
      Miniswen::LocalRoute.verify!(model_ids: [ "direct" ], checkpoint: { sha256: SHA, bytes: BYTES },
                                  fetch: ->(*) { { "data" => [ bare ] } })
    end

    assert_equal "local model \"direct\" does not identify a checkpoint " \
                 "(expected checkpoint.sha256, checkpoint.bytes, and checkpoint.arm)", error.message

    account = Miniswen::LocalRoute.account(
      "usage" => { "prompt_tokens" => 10, "completion_tokens" => 4 },
      "lecore" => { "requests" => 3, "phases" => [ { "name" => "weighted", "duration" => 0.029 } ] }
    )

    assert_equal 10, account[:prompt_tokens]
    assert_equal 4, account[:generated_tokens]
    refute account[:reasoning_reported]
    assert_nil account[:reasoning_tokens]
    assert_equal 3, account[:model_requests]
    assert account[:phases_reported]
    assert_equal "weighted", account[:phases].first[:name]

    assert_raises(Miniswen::AccountingError) do
      Miniswen::LocalRoute.account("lemans" => { "phases" => [ { "name" => "weighted" } ] })
    end

    assert_equal "local-dummy", Miniswen::LocalRoute.api_key(nil)
    assert_equal "local-dummy", Miniswen::LocalRoute::DUMMY_KEY
  end

  def test_a_local_run_records_full_usage_and_strips_secrets_from_the_shell
    ENV["OPENAI_API_KEY"] = "sk-test-secret"
    raw = Faraday::Response.new(body: {
                                  "usage" => {
                                    "prompt_tokens" => 10, "completion_tokens" => 4,
                                    "completion_tokens_details" => { "reasoning_tokens" => 3 }
                                  },
                                  "lemans" => {
                                    "requests" => 2, "generated_tokens" => 9, "cost_usd" => 0.5,
                                    "phases" => [ { "name" => "weighted", "duration" => 0.029, "tokens" => 1 } ]
                                  }
                                })
    ticks = [ 0.0, 1.0, 1.25 ]
    env = RecordingEnv.new
    agent = build_local(env, clock: -> { ticks.shift || 1.25 })
    stub_llm({ **SUBMIT, raw:, input_tokens: 1, output_tokens: 1, cached_tokens: 0 })

    result = agent.run("task")

    assert_equal :submitted, result.status
    assert_equal 10, result.input_tokens
    assert_equal 9, result.output_tokens
    assert_equal 3, result.thinking_tokens
    assert_equal 1, result.requests
    assert_equal 2, result.model_requests
    assert_equal 9, result.generated_tokens
    assert_in_delta 0.25, result.model_duration
    assert_equal [ { name: "weighted", duration: 0.029, tokens: 1 } ], result.phases
    assert_in_delta 0.5, result.cost_usd
    assert_equal :provider_reported, result.cost_source.name
    assert_includes result.cost_source.priced_as, "127.0.0.1"
    assert env.envs.first.key?("OPENAI_API_KEY")
    assert_nil env.envs.first["OPENAI_API_KEY"]
    assert_nil env.envs.first["LEMANS_LOCAL_API_KEY"]
    assert_equal "cat", env.envs.first["PAGER"]

    trajectory = JSON.parse(JSON.generate(Miniswen::Trajectory.from(result, model: "local/direct").to_atif))
    turn = trajectory["steps"].find { it["source"] == "agent" }

    assert_equal 2, turn["llm_call_count"]
    assert_equal 3, turn.dig("metrics", "extra", "completion_tokens_details", "reasoning_tokens")
    assert_equal "127.0.0.1", turn.dig("metrics", "extra", "endpoint")
    assert_in_delta 0.25, trajectory.dig("final_metrics", "extra", "model_duration")
    assert_equal 9, trajectory.dig("final_metrics", "extra", "generated_tokens")

    partial = { "usage" => { "prompt_tokens" => 6, "completion_tokens" => 2 } }
    stub_llm({ **SUBMIT, raw: Faraday::Response.new(body: partial) })
    quiet = build_local(RecordingEnv.new).run("task")

    assert_equal 6, quiet.input_tokens
    assert_equal 2, quiet.output_tokens
    assert_nil quiet.thinking_tokens
    assert_nil quiet.model_requests
    assert_nil quiet.phases
    assert_equal 1, quiet.requests
    assert_in_delta 0.0, quiet.cost_usd
    assert_equal :local_provider, quiet.cost_source.name

    restored = Miniswen::Agent::Result.from_h(JSON.parse(JSON.generate(result.to_h)))

    assert_equal result.phases, restored.phases
    assert_equal 3, restored.thinking_tokens
    assert_equal 2, restored.model_requests
    assert_nil Miniswen::Agent::Result.from_h(JSON.parse(JSON.generate(quiet.to_h))).thinking_tokens
  ensure
    ENV.delete("OPENAI_API_KEY")
  end

  def test_provider_env_is_the_dummy_route_and_the_bench_wires_both_arms
    ENV["OPENAI_API_KEY"] = "sk-test-secret"
    ENV["LEMANS_LOCAL_API_KEY"] = "local-dummy"
    agent = build_local(RecordingEnv.new, checkpoint: { sha256: SHA, bytes: BYTES })

    env = agent.provider_env

    assert_equal "http://127.0.0.1:9/v1", env["LEMANS_LOCAL_API_BASE"]
    assert_equal "local-dummy", env["LEMANS_LOCAL_API_KEY"]
    assert_equal SHA, env["LEMANS_LOCAL_CHECKPOINT_SHA256"]
    assert_equal BYTES.to_s, env["LEMANS_LOCAL_CHECKPOINT_BYTES"]
    refute env.key?("OPENAI_API_KEY")

    config = Lemans::Config.load_file(File.expand_path("../../examples/ds41-local", __dir__))
    instruction = config.tasks.first.instruction
    grader = File.read(File.expand_path("../../examples/ds41-local/tasks/smoke/verification_test.rb", __dir__))

    assert_equal [ "local/direct", "local/lecore" ], config.models
    assert_equal SHA, config.agent.local_checkpoint[:sha256]
    assert_equal BYTES, config.agent.local_checkpoint[:bytes]
    assert_equal "none", config.agent.environment.network.mode
    refute_includes instruction, "assert_equal"
    refute_includes instruction, "SmokeTest"
    assert_includes grader, 'assert_equal "ok"'

    harness = Lemans::Agents.build("miniswen", profile: config.agent, model: "local/direct")
    inner = harness.send(:agent_for, RecordingEnv.new)

    assert_equal SHA, inner.instance_variable_get(:@checkpoint)[:sha256]
    assert_equal %w[direct lecore], inner.instance_variable_get(:@local_model_ids).map { Miniswen::LocalRoute.model_id(it) }

    mismatch = assert_raises(Lemans::ConfigError) do
      Miniswen::LocalRoute.stub(:fetch_models, { "data" => [ row("direct") ] }) do
        stub_llm(SUBMIT)
        harness.run(config.tasks.first, RecordingEnv.new)
      end
    end

    assert_equal "local model \"lecore\" is not in the router model list", mismatch.message
  ensure
    ENV.delete("OPENAI_API_KEY")
    ENV.delete("LEMANS_LOCAL_API_KEY")
  end

  private

  def row(id, bytes: BYTES)
    { "id" => id, "checkpoint" => { "sha256" => SHA, "bytes" => bytes, "arm" => id } }
  end

  def build_local(env, **options)
    Miniswen::Agent.new(
      model: "local/direct", environment: env,
      checkpoint: { sha256: SHA, bytes: BYTES },
      local_model_ids: %w[local/direct local/lecore],
      model_list: ->(*) { { "data" => [ row("direct"), row("lecore") ] } },
      **options
    )
  end
end
