# frozen_string_literal: true

require "test_helper"
require "json"

class ResultTest < Minitest::Test
  def build_result(**) = Lemans::Result.new(task: "hello-world", agent: "oracle", model: "m/model-a", index: 1, **)

  def test_lifecycle
    result = build_result

    assert_predicate result.outcome, :pending?
    assert_predicate result, :invalid?

    result.phase_started(:agent)
    result.phase_finished(:agent)
    result.completed!(:completed, Lemans::Result::Usage.zero)
    result.graded!(0.5)

    assert_predicate result, :scored?
    assert_equal :completed, result.status
    assert_in_delta 0.5, result.reward
    assert_in_delta 0.5, result.credit

    result.graded!(1.0, credit: 0.7)

    assert_in_delta 1.0, result.reward
    assert_in_delta 0.7, result.credit
    assert_kind_of Float, result.duration
  end

  def test_failures_do_not_cascade
    result = build_result
    result.failed!(:agent_error, "first")
    result.failed!(:environment_error, "second")

    assert_equal :agent_error, result.status
    assert_equal "first", result.detail
    assert_nil result.reward
    assert_nil result.credit
  end

  def test_phases_enforce_order
    result = build_result
    result.phase_started(:one)

    assert_raises(ArgumentError) { result.phase_started(:two) }
    assert_raises(ArgumentError) { result.phase_finished(:two) }

    result.phase_finished(:one)

    assert_raises(ArgumentError) { build_result.phase_finished(:one) }
  end

  def test_usage_plus
    source = Lemans::Result::CostSource.new(name: :model_registry, model: "m", priced_as: "m", registry: "r")
    first = Lemans::Result::Usage.new(input_tokens: 100, output_tokens: 10, cached_tokens: 50, steps: 3,
                                      cost_usd: 0.5, cost_source: nil)
    second = Lemans::Result::Usage.new(input_tokens: 200, output_tokens: 20, cached_tokens: 60, steps: 4,
                                       cost_usd: 0.25, cost_source: source)
    total = first + second

    assert_equal 300, total.input_tokens
    assert_equal 30, total.output_tokens
    assert_equal 110, total.cached_tokens
    assert_equal 7, total.steps
    assert_in_delta 0.75, total.cost_usd
    assert_equal source, total.cost_source

    unknown = total + Lemans::Result::Usage.new(input_tokens: 1, output_tokens: 1, cached_tokens: 0, steps: 1,
                                                cost_usd: nil, cost_source: nil)

    assert_nil unknown.cost_usd
    assert_equal source, unknown.cost_source
  end

  def test_usage_accounting
    left = Lemans::Result::Usage.new(input_tokens: 1, output_tokens: 1, cached_tokens: 0, steps: 1, cost_usd: 0,
                                    cost_source: nil, accounting: { "requests" => 1, "reasoning_tokens" => nil,
                                                                    "phases" => [ { name: "weighted", duration: 0.029 } ] })
    right = Lemans::Result::Usage.new(input_tokens: 1, output_tokens: 1, cached_tokens: 0, steps: 1, cost_usd: 0,
                                     cost_source: nil, accounting: { "requests" => 2, "reasoning_tokens" => 4,
                                                                     "phases" => [ { "name" => "weighted", "duration" => 0.001, "tokens" => 3 } ] })
    summed = left + right

    assert_equal 3, summed.accounting["requests"]
    assert_nil summed.accounting["reasoning_tokens"]
    assert_in_delta 0.03, summed.accounting["phases"].first[:duration]
    assert_nil summed.accounting["phases"].first[:tokens]

    gap = summed + Lemans::Result::Usage.zero

    assert_nil gap.accounting
  end

  def test_step_completed
    result = build_result
    usage = Lemans::Result::Usage.new(input_tokens: 10, output_tokens: 5, cached_tokens: 0, steps: 2,
                                      cost_usd: 0.1, cost_source: nil)
    result.step_completed!(:completed, usage, duration: 3.0)

    assert_equal :completed, result.status
    assert_predicate result, :scored?
    assert_in_delta 0.1, result.usage.cost_usd

    result.step_completed!(:step_limit_reached, usage, duration: 4.0)

    assert_equal 2, result.steps.size
    assert_equal %i[completed step_limit_reached], result.steps.map { it.outcome.status }
    assert_equal [ 3.0, 4.0 ], result.steps.map(&:duration)

    assert_equal :step_limit_reached, result.status
    assert_equal 4, result.usage.steps
    assert_in_delta 0.2, result.usage.cost_usd
  end

  def test_json_round_trip
    result = build_result
    result.phase_started(:agent)
    result.phase_finished(:agent)
    result.completed!(:completed, Lemans::Result::Usage.zero)
    result.graded!(1.0, credit: 0.8)

    data = JSON.parse(JSON.generate(result.as_json), symbolize_names: true)
    restored = Lemans::Result.from_json(data)

    assert_equal Lemans::VERSION, data[:lemans_version]
    assert_equal result.id, restored.id
    assert_equal 1, restored.index
    assert_equal :completed, restored.status
    assert_predicate restored, :scored?
    assert_in_delta 1.0, restored.reward
    assert_in_delta 0.8, restored.credit
    assert_equal %i[agent], restored.phases.map(&:name)
    assert_equal 0, restored.usage.steps
  end

  def test_reads_legacy_result_json
    data = {
      trial: "t__abc1234", task: "t", agent: "oracle", model: "m",
      reward: 1.0, outcome: { name: "completed", scored: true },
      duration_sec: 12.3, bench: { commit: "abc", dirty: false },
      profile_digest: "0" * 16, task_digest: "1" * 16,
      phases: { environment_setup: { started_at: "2026-08-19T00:00:00Z", finished_at: "2026-08-19T00:01:00Z" } }
    }
    result = Lemans::Result.from_json(data)

    assert_equal :completed, result.status
    assert_predicate result, :scored?
    assert_in_delta 1.0, result.credit
    assert_in_delta 12.3, result.duration
    assert_equal "abc", result.revision.commit
    assert_equal %i[environment_setup], result.phases.map(&:name)
  end

  def failed_multistep_result
    usage = Lemans::Result::Usage.new(input_tokens: 10, output_tokens: 5, cached_tokens: 0, steps: 2,
                                      cost_usd: 0.1, cost_source: nil)
    source = build_result
    t0 = Time.utc(2026, 10, 5, 7, 0, 0)
    [ [ :environment_setup, 0, 10 ], [ :"agent.1", 10, 100 ], [ :"verifier.1", 105, 120 ],
      [ :"agent.2", 122, 200 ], [ :"verifier.2", 205, 220 ], [ :"agent.3", 222, 230 ] ].each do |name, from, to|
      source.phase_started(name, t0 + from)
      source.phase_finished(name, t0 + to)
    end
    3.times { source.step_completed!(:completed, usage, duration: 1.0) }
    source.failed!(:agent_error, "the provider went away")
  end

  def restarted(source, step:, mode: nil, names: nil, through: nil, now: Time.utc(2026, 10, 6, 12, 0, 0))
    result = build_result.restart!(source, step:, mode:)
    result.phase_started(:environment_setup, now - 30)
    result.phase_finished(:environment_setup, now - 5)
    result.adopt_phases!(source, names, **{ through:, now: }.compact)
  end

  def test_restart
    source = failed_multistep_result

    assert_equal 2, source.settled_steps
    assert_equal 0, build_result.settled_steps
    assert_equal 2, source.verified_step
    assert_nil build_result.verified_step

    now = Time.utc(2026, 10, 6, 12, 0, 0)
    result = restarted(source, step: 3, names: %i[agent.1 verifier.1 agent.2 verifier.2], now:)

    assert_equal Lemans::Result::Restart.new(trial: source.id, step: 3), result.restarted_from
    assert_equal 2, result.steps.size
    assert_in_delta 0.2, result.usage.cost_usd
    assert_equal %i[environment_setup agent.1 verifier.1 agent.2 verifier.2], result.phases.map(&:name)

    # The settled phases end now, the new setup moved back in front of them
    # keeping its own length; the gaps of the original run survive.
    assert_equal now, result.phases.last.finished_at
    assert_equal now - 210, result.phases[1].started_at
    assert_equal now - 210, result.phases[0].finished_at
    assert_in_delta 25.0, result.phases[0].duration
    assert_in_delta 235.0, result.duration

    restored = Lemans::Result.from_json(JSON.parse(JSON.generate(result.as_json), symbolize_names: true))

    assert_equal result.restarted_from, restored.restarted_from
    assert_nil Lemans::Result.from_json(JSON.parse(JSON.generate(source.as_json), symbolize_names: true)).restarted_from
  end

  def test_total_steps
    halted = failed_multistep_result

    assert_nil build_result.total_steps
    assert_nil halted.total_steps

    halted.total_steps = 5
    restored = Lemans::Result.from_json(JSON.parse(JSON.generate(halted.as_json), symbolize_names: true))

    assert_equal 5, restored.total_steps
  end

  def test_features
    result = build_result.completed!(:completed, Lemans::Result::Usage.zero)
    result.graded!(1.0, features: { "migrations" => true, "archspec" => false })
    restored = Lemans::Result.from_json(JSON.parse(JSON.generate(result.as_json), symbolize_names: true))

    assert_equal({ "migrations" => true, "archspec" => false }, restored.features)

    restored.failed!(:verifier_error, "the tests crashed")

    assert_nil restored.features
    assert_nil Lemans::Result.from_json(JSON.parse(JSON.generate(build_result.as_json), symbolize_names: true)).features
  end

  def test_restart_modes
    source = failed_multistep_result
    now = Time.utc(2026, 10, 6, 12, 0, 0)

    # A recovery aligns on the partial phase it continues, without copying it.
    recovered = restarted(source, step: 3, mode: :recover, names: %i[agent.1 verifier.1 agent.2 verifier.2],
                                  through: :"agent.3", now:)

    assert_equal "recover", recovered.restarted_from.mode
    assert_equal 2, recovered.steps.size
    # agent.3 ran 8s, 2s after verifier.2: its continuation starts at now - 8.
    assert_equal now - 10, recovered.phases.last.finished_at

    # A reverification carries the graded step along with its agent phase.
    reverified = restarted(source, step: 2, mode: :reverify, names: %i[agent.1 verifier.1 agent.2], now:)

    assert_equal 2, reverified.steps.size
    assert_equal %i[environment_setup agent.1 verifier.1 agent.2], reverified.phases.map(&:name)
    assert_equal now, reverified.phases.last.finished_at

    # A single-step run graded before keeps its agent outcome and usage.
    single = build_result
    single.phase_started(:agent)
    single.phase_finished(:agent)
    single.phase_started(:verifier)
    single.phase_finished(:verifier)
    single.completed!(:step_limit_reached, Lemans::Result::Usage.zero).graded!(0.0)

    assert_equal 1, single.verified_step

    regraded = build_result.restart!(single, step: 1, mode: :reverify)

    assert_equal :step_limit_reached, regraded.status
    assert_nil regraded.reward
    assert_equal({ trial: single.id, step: 1, mode: "reverify" }, regraded.restarted_from.as_json)
  end

  def test_an_unknown_outcome_is_incompatible
    assert_raises(Lemans::Result::IncompatibleError) { Lemans::Result::Outcome.new(:gone_fishing) }
  end
end
