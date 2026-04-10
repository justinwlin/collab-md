defmodule CollabMd.RoomSupervisor do
  @moduledoc """
  DynamicSupervisor that spawns and manages Room processes.

  Each room is started as a supervised child identified by its unique code.
  Room processes register themselves in CollabMd.RoomRegistry via the
  `{:via, Registry, {CollabMd.RoomRegistry, code}}` name.
  """

  use DynamicSupervisor

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Generates a unique 6-character hex room code, starts a supervised Room
  process for it, and returns `{:ok, code}`.
  """
  @max_rooms 200

  @spec create_room() :: {:ok, String.t()} | {:error, :room_limit_reached}
  def create_room do
    if room_count() >= @max_rooms do
      {:error, :room_limit_reached}
    else
      code = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
      {:ok, _pid} = DynamicSupervisor.start_child(__MODULE__, {CollabMd.Room, %{code: code}})
      {:ok, code}
    end
  end

  @doc "Returns the number of active rooms."
  @spec room_count() :: non_neg_integer()
  def room_count do
    DynamicSupervisor.count_children(__MODULE__).active
  end

  @doc """
  Returns `true` if a Room process with the given code is currently registered,
  `false` otherwise.
  """
  @spec room_exists?(String.t()) :: boolean()
  def room_exists?(code) do
    case Registry.lookup(CollabMd.RoomRegistry, code) do
      [] -> false
      [_ | _] -> true
    end
  end

  # ---------------------------------------------------------------------------
  # DynamicSupervisor callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
