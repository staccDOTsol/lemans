# frozen_string_literal: true

require "test_helper"

require "miniswen/testing"

class DsmlTest < Minitest::Test
  include Miniswen::Testing

  TOKEN = Miniswen::LocalRoute::Dsml::TOKEN

  def test_textual_invokes_become_exact_bash_calls_and_the_cap_counts_the_rest
    exact = '<invoke name="bash"><parameter name="command" string="true">ls app</parameter></invoke>'
    parsed = Miniswen::LocalRoute::Dsml.parse(exact)

    assert_equal "degraded_invoke", parsed[:parse_path]
    assert_equal [ { "command" => "ls app" } ], parsed[:calls].map { it[:arguments] }
    assert_equal "call_dsml_1", parsed[:calls].first[:id]
    assert_equal "bash", parsed[:calls].first[:name]
    assert_empty parsed[:errors]
    assert_equal 0, parsed[:omitted]

    spaced = '<invoke name="bash"><parameter name="command" string="true">ls  "app"</parameter></invoke>'

    assert_equal 'ls  "app"', Miniswen::LocalRoute::Dsml.parse(spaced)[:calls].first[:arguments]["command"]

    hybrid = <<~TEXT
      <bash>
      <#{TOKEN}invoke name="bash">
      <#{TOKEN}parameter name="command" string="true">ls app</#{TOKEN}parameter>
      </#{TOKEN}invoke>
      </bash>
    TEXT
    bridged = Miniswen::LocalRoute::Dsml.parse(hybrid)

    assert_equal "dsml", bridged[:parse_path]
    assert_equal "ls app", bridged[:calls].first[:arguments]["command"]
    refute_includes bridged[:content], "invoke"

    unknown = '<invoke name="python"><parameter name="command" string="true">ls app</parameter></invoke>'
    extra = '<invoke name="bash"><parameter name="path" string="true">app</parameter></invoke>'
    typed = '<invoke name="bash"><parameter name="command" string="false">"ls app"</parameter></invoke>'
    residue = '<invoke name="bash"><parameter name="command" string="true">ls app</parameter>rm</invoke>'
    empty = '<invoke name="bash"></invoke>'

    [ unknown, extra, typed, residue, empty ].each do |text|
      rejected = Miniswen::LocalRoute::Dsml.parse(text)

      assert_empty rejected[:calls], text
      assert_equal "degraded_invoke_failed", rejected[:parse_path]
      refute_empty rejected[:errors]
    end

    distinct = [
      exact,
      '<invoke name="bash"><parameter name="command" string="true">find app -type f</parameter></invoke>',
      '<invoke name="bash"><parameter name="command" string="true">ls app</parameter></invoke>'
    ].join
    uncapped = Miniswen::LocalRoute::Dsml.parse(distinct)

    assert_equal [ "ls app", "find app -type f", "ls app" ], uncapped[:calls].map { it[:arguments]["command"] }
    assert_equal 0, uncapped[:omitted]

    capped = Miniswen::LocalRoute::Dsml.parse(distinct, limit: 1)

    assert_equal [ "ls app" ], capped[:calls].map { it[:arguments]["command"] }
    assert_equal 2, capped[:omitted]
    assert_includes capped[:raw], "find app -type f"

    structured = Miniswen::LocalRoute::Dsml.apply(
      content: "raw text",
      tool_calls: [
        { id: "call_a", name: "bash", arguments: { "command" => "ls app" } },
        { id: "call_b", name: "bash", arguments: { "command" => "pwd" } },
        { id: "call_c", name: "rm", arguments: { "command" => "x" } }
      ],
      limit: 1
    )

    assert_equal "openai", structured[:parse_path]
    assert_equal [ "call_a" ], structured[:calls].map { it[:id] }
    assert_equal "ls app", structured[:calls].first[:arguments]["command"]
    assert_equal 1, structured[:omitted]
    assert_equal 1, structured[:errors].size
    assert_equal "raw text", structured[:raw]
  end

  def test_the_local_option_runs_the_first_command_and_keeps_the_full_generation
    base = RubyLLM.config.lemans_local_api_base
    RubyLLM.configure { it.lemans_local_api_base = "http://127.0.0.1:9/v1" }
    text = <<~TEXT
      Look.
      <invoke name="bash"><parameter name="command" string="true">ls app</parameter></invoke>
      <invoke name="bash"><parameter name="command" string="true">find app -type f</parameter></invoke>
      <invoke name="bash"><parameter name="command" string="true">ls  app</parameter></invoke>
    TEXT
    usage = Struct.new(:body).new({ "usage" => { "prompt_tokens" => 12, "completion_tokens" => 2048 } })
    env = FakeEnv.new
    agent = build_agent(env, dsml: true, bash_call_limit: 1)
    stub_llm(
      { content: text, tool_calls: [], raw: usage, input_tokens: 12, output_tokens: 2048, cached_tokens: 0 },
      SUBMIT
    )

    result = agent.run("task")
    turn = result.messages.find { it.dig(:metrics, :dsml) }

    assert_equal :submitted, result.status
    assert_includes env.commands, "ls app"
    refute_includes env.commands, "find app -type f"
    refute_includes env.commands, "ls  app"
    assert_equal 2048, turn[:metrics][:completion_tokens]
    assert_equal 2048, turn[:metrics][:generated_tokens]
    assert_equal 2, turn.dig(:metrics, :dsml, :omitted)
    assert_includes turn.dig(:metrics, :dsml, :raw), "find app -type f"
    refute_includes turn[:content], "<invoke"
    assert_operator result.output_tokens, :>=, 2048

    quiet = FakeEnv.new
    stub_llm({ content: text, tool_calls: [] }, { content: text, tool_calls: [] }, { content: text, tool_calls: [] })
    build_agent(quiet, dsml: false).run("task")

    refute_includes quiet.commands, "ls app"

    config = Lemans::Config.load_file(File.expand_path("../../examples/ds41-local", __dir__))

    assert config.agent.local_dsml
    assert_equal 1, config.agent.local_bash_call_limit
    assert_equal 100, config.agent.step_limit
    assert_equal 30 * 60, config.agent.timeout
  ensure
    RubyLLM.configure { it.lemans_local_api_base = base }
  end

  private

  def build_agent(env, **)
    Miniswen::Agent.new(
      model: "local/direct", environment: env,
      checkpoint: { sha256: "ab" * 32, bytes: 4 },
      local_model_ids: %w[local/direct],
      model_list: ->(*) { { "data" => [ { "id" => "direct", "checkpoint" => { "sha256" => "ab" * 32, "bytes" => 4, "arm" => "direct" } } ] } },
      **
    )
  end
end
