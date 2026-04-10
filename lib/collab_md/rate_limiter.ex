defmodule CollabMd.RateLimiter do
  @moduledoc """
  Simple in-memory rate limiter using ETS with fixed time windows.
  No external dependencies needed.
  """

  use GenServer

  @table :rate_limiter
  @cleanup_interval_ms 60_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Check if an action is within rate limits.
  Returns :ok or {:error, :rate_limited}.

  - key: any term identifying the actor + action (e.g. {:room_create, "1.2.3.4"})
  - limit: max allowed actions per window
  - window_seconds: size of the time window
  """
  @spec check_rate(term(), pos_integer(), pos_integer()) :: :ok | {:error, :rate_limited}
  def check_rate(key, limit, window_seconds) do
    now = System.system_time(:second)
    window = div(now, window_seconds)
    full_key = {key, window}

    count = :ets.update_counter(@table, full_key, {2, 1}, {full_key, 0})

    if count <= limit do
      :ok
    else
      {:error, :rate_limited}
    end
  end

  # GenServer callbacks

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
    schedule_cleanup()
    {:ok, nil}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:second)
    cutoff = now - 120

    :ets.select_delete(@table, [
      {{{{:_, :_}, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}
    ])

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval_ms)
end
