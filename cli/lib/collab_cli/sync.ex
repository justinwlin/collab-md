defmodule CollabCli.Sync do
  use GenServer

  @poll_interval 500

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def remote_update(content) do
    GenServer.cast(__MODULE__, {:remote_update, content})
  end

  @impl true
  def init(opts) do
    file_path = opts[:file_path]
    initial = opts[:initial_content] || ""
    File.write!(file_path, initial)

    schedule_poll()

    {:ok,
     %{
       file_path: file_path,
       username: opts[:username],
       channel_pid: opts[:channel_pid],
       last_content: initial,
       last_mtime: file_mtime(file_path),
       skip_next_poll: false
     }}
  end

  @impl true
  def handle_info(:poll, state) do
    schedule_poll()

    if state.skip_next_poll do
      {:noreply, %{state | skip_next_poll: false}}
    else
      mtime = file_mtime(state.file_path)

      if mtime != state.last_mtime do
        case File.read(state.file_path) do
          {:ok, content} when content != state.last_content ->
            CollabCli.ChannelClient.send_update(state.channel_pid, content, state.username)
            {:noreply, %{state | last_content: content, last_mtime: mtime}}

          _ ->
            {:noreply, %{state | last_mtime: mtime}}
        end
      else
        {:noreply, state}
      end
    end
  end

  @impl true
  def handle_cast({:remote_update, content}, state) do
    if content != state.last_content do
      File.write!(state.file_path, content)
      {:noreply, %{state | last_content: content, last_mtime: file_mtime(state.file_path), skip_next_poll: true}}
    else
      {:noreply, state}
    end
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval)

  defp file_mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> nil
    end
  end
end
