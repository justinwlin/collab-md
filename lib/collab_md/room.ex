defmodule CollabMd.Room do
  @moduledoc """
  GenServer managing per-room state for a collaborative markdown session.

  Each room holds:
  - The current markdown document
  - Versioned snapshots (newest first)
  - The set of connected users
  - An idle timeout that shuts down the process when unused
  """

  use GenServer

  @default_timeout_ms 4 * 60 * 60 * 1_000
  @last_user_timeout_ms 30 * 60 * 1_000

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc "Starts and registers the Room GenServer under the given room code."
  def start_link(%{code: code}) do
    GenServer.start_link(__MODULE__, code, name: via(code))
  end

  @doc "Returns the current document content."
  @spec get_document(String.t()) :: {:ok, String.t()}
  def get_document(code) do
    GenServer.call(via(code), :get_document)
  end

  @doc """
  Saves the current document as a new version snapshot and sets the new content.
  Returns {:ok, new_version_number}.
  """
  @spec update_document(String.t(), String.t(), String.t()) :: {:ok, non_neg_integer()}
  def update_document(code, content, author) do
    GenServer.call(via(code), {:update_document, content, author})
  end

  @doc "Returns version metadata (number, author, timestamp) — newest first, no content."
  @spec get_versions(String.t()) :: {:ok, list(map())}
  def get_versions(code) do
    GenServer.call(via(code), :get_versions)
  end

  @doc """
  Restores a previous version's content as the current document,
  creating a new version snapshot in the process.
  """
  @spec restore_version(String.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, :not_found}
  def restore_version(code, number) do
    GenServer.call(via(code), {:restore_version, number})
  end

  @doc """
  Applies a diff patch to the current document, but only if base_version matches.
  Returns {:ok, new_version} or {:error, :version_mismatch, current_doc, current_version}.
  """
  @spec apply_patch(String.t(), list(map()), String.t(), non_neg_integer()) ::
          {:ok, non_neg_integer()}
          | {:error, :version_mismatch, String.t(), non_neg_integer()}
          | {:error, atom()}
  def apply_patch(code, ops, author, base_version) do
    GenServer.call(via(code), {:apply_patch, ops, author, base_version})
  end

  @doc "Adds a user to the room's connected-user set."
  @spec join(String.t(), String.t()) :: :ok
  def join(code, username) do
    GenServer.call(via(code), {:join, username})
  end

  @doc "Removes a user from the room's connected-user set (fire-and-forget cast)."
  @spec leave(String.t(), String.t()) :: :ok
  def leave(code, username) do
    GenServer.cast(via(code), {:leave, username})
  end

  @doc "Stores a CRDT update (opaque binary) and updates the plain text document."
  @spec apply_crdt_update(String.t(), binary(), String.t(), String.t()) ::
          {:ok, non_neg_integer()}
  def apply_crdt_update(code, update_binary, text, author) do
    GenServer.call(via(code), {:apply_crdt_update, update_binary, text, author})
  end

  @doc "Returns the list of accumulated CRDT updates (chronological order)."
  @spec get_crdt_state(String.t()) :: {:ok, list(binary())}
  def get_crdt_state(code) do
    GenServer.call(via(code), :get_crdt_state)
  end

  @doc "Returns a summary of current room state."
  @spec status(String.t()) :: {:ok, map()}
  def status(code) do
    GenServer.call(via(code), :status)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(code) do
    state = %{
      code: code,
      document: "",
      versions: [],
      version_count: 0,
      crdt_updates: [],
      users: MapSet.new(),
      created_at: DateTime.utc_now(),
      idle_timer: schedule_timeout(@default_timeout_ms)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_document, _from, state) do
    state = reset_timer(state, @default_timeout_ms)
    {:reply, {:ok, state.document}, state}
  end

  def handle_call({:update_document, content, author}, _from, state) do
    new_version_number = state.version_count + 1

    # Snapshot records what the document becomes at this version number.
    snapshot = %{
      number: new_version_number,
      content: content,
      author: author,
      timestamp: DateTime.utc_now()
    }

    new_versions = [snapshot | state.versions]

    state =
      state
      |> Map.put(:document, content)
      |> Map.put(:versions, new_versions)
      |> Map.put(:version_count, new_version_number)
      |> Map.put(:crdt_updates, [])
      |> reset_timer(@default_timeout_ms)

    {:reply, {:ok, new_version_number}, state}
  end

  def handle_call({:apply_crdt_update, update_binary, text, author}, _from, state) do
    new_version_number = state.version_count + 1

    snapshot = %{
      number: new_version_number,
      content: text,
      author: author,
      timestamp: DateTime.utc_now()
    }

    state =
      state
      |> Map.put(:document, text)
      |> Map.put(:versions, [snapshot | state.versions])
      |> Map.put(:version_count, new_version_number)
      |> Map.update!(:crdt_updates, &[update_binary | &1])
      |> reset_timer(@default_timeout_ms)

    {:reply, {:ok, new_version_number}, state}
  end

  def handle_call(:get_crdt_state, _from, state) do
    state = reset_timer(state, @default_timeout_ms)
    {:reply, {:ok, Enum.reverse(state.crdt_updates)}, state}
  end

  def handle_call(:get_versions, _from, state) do
    metadata = Enum.map(state.versions, &Map.take(&1, [:number, :author, :timestamp]))
    {:reply, {:ok, metadata}, state}
  end

  def handle_call({:restore_version, number}, _from, state) do
    case Enum.find(state.versions, fn v -> v.number == number end) do
      nil ->
        {:reply, {:error, :not_found}, state}

      version ->
        restored_content = version.content

        new_version_number = state.version_count + 1

        # Snapshot records the restored content at the new version number.
        snapshot = %{
          number: new_version_number,
          content: restored_content,
          author: "restore",
          timestamp: DateTime.utc_now()
        }

        new_versions = [snapshot | state.versions]

        state =
          state
          |> Map.put(:document, restored_content)
          |> Map.put(:versions, new_versions)
          |> Map.put(:version_count, new_version_number)
          |> reset_timer(@default_timeout_ms)

        {:reply, {:ok, restored_content}, state}
    end
  end

  def handle_call({:apply_patch, ops, author, base_version}, _from, state) do
    if base_version != state.version_count do
      {:reply, {:error, :version_mismatch, state.document, state.version_count}, state}
    else
      case CollabMd.Patch.apply(state.document, ops) do
        {:ok, new_content} ->
          new_version_number = state.version_count + 1

          snapshot = %{
            number: new_version_number,
            content: new_content,
            author: author,
            timestamp: DateTime.utc_now()
          }

          state =
            state
            |> Map.put(:document, new_content)
            |> Map.put(:versions, [snapshot | state.versions])
            |> Map.put(:version_count, new_version_number)
            |> reset_timer(@default_timeout_ms)

          {:reply, {:ok, new_version_number}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:join, username}, _from, state) do
    new_users = MapSet.put(state.users, username)

    state =
      state
      |> Map.put(:users, new_users)
      |> reset_timer(@default_timeout_ms)

    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state) do
    result = %{
      users: MapSet.to_list(state.users),
      version: state.version_count,
      created_at: state.created_at
    }

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_cast({:leave, username}, state) do
    new_users = MapSet.delete(state.users, username)

    timeout =
      if MapSet.size(new_users) == 0 do
        @last_user_timeout_ms
      else
        @default_timeout_ms
      end

    state =
      state
      |> Map.put(:users, new_users)
      |> reset_timer(timeout)

    {:noreply, state}
  end

  @impl true
  def handle_info(:idle_timeout, state) do
    {:stop, :normal, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp via(code), do: {:via, Registry, {CollabMd.RoomRegistry, code}}

  defp schedule_timeout(ms) do
    Process.send_after(self(), :idle_timeout, ms)
  end

  defp reset_timer(%{idle_timer: ref} = state, ms) do
    Process.cancel_timer(ref)
    new_ref = schedule_timeout(ms)
    %{state | idle_timer: new_ref}
  end

end
