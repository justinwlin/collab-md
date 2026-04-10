defmodule CollabMd.RateLimiterTest do
  use ExUnit.Case, async: false

  alias CollabMd.RateLimiter

  test "allows requests within limit" do
    key = {:test, System.unique_integer([:positive])}
    assert :ok = RateLimiter.check_rate(key, 5, 60)
    assert :ok = RateLimiter.check_rate(key, 5, 60)
    assert :ok = RateLimiter.check_rate(key, 5, 60)
  end

  test "blocks requests over limit" do
    key = {:test_block, System.unique_integer([:positive])}

    for _ <- 1..3 do
      assert :ok = RateLimiter.check_rate(key, 3, 60)
    end

    assert {:error, :rate_limited} = RateLimiter.check_rate(key, 3, 60)
  end

  test "different keys are independent" do
    base = System.unique_integer([:positive])
    key_a = {:test_a, base}
    key_b = {:test_b, base}

    for _ <- 1..3 do
      RateLimiter.check_rate(key_a, 3, 60)
    end

    assert {:error, :rate_limited} = RateLimiter.check_rate(key_a, 3, 60)
    assert :ok = RateLimiter.check_rate(key_b, 3, 60)
  end
end
