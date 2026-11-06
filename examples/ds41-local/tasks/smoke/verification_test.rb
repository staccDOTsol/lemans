# frozen_string_literal: true

require "minitest/autorun"

class SmokeTest < Minitest::Test
  def test_smoke_file
    path = "/app/smoke.txt"
    assert File.file?(path), "expected #{path} to exist"
    assert_equal "ok", File.read(path).strip
  end
end
