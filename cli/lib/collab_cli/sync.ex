defmodule CollabCli.Sync do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def remote_update(content) do
    GenServer.cast(__MODULE__, {:remote_update, content})
  end

  @impl true
  def init(opts) do
    file_path = opts[:file_path]
    File.write!(file_path, opts[:initial_content] || "")

    {:ok, watcher_pid} = FileSystem.start_link(dirs: [Path.dirname(file_path)])
    FileSystem.subscribe(watcher_pid)

    {:ok,
     %{
       file_path: file_path,
       username: opts[:username],
       channel_pid: opts[:channel_pid],
       watcher_pid: watcher_pid,
       last_content: opts[:initial_content] || "",
       skip_next_write: false
     }}
  end

  @impl true
  def handle_info({:file_event, _pid, {path, events}}, state) do
    if Path.basename(path) == Path.basename(state.file_path) and :modified in events do
      if state.skip_next_write do
        {:noreply, %{state | skip_next_write: false}}
      else
        case File.read(state.file_path) do
          {:ok, content} when content != state.last_content ->
            CollabCli.ChannelClient.send_update(state.channel_pid, content, state.username)
            {:noreply, %{state | last_content: content}}

          _ ->
            {:noreply, state}
        end
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _pid, :stop}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:remote_update, content}, state) do
    if content != state.last_content do
      File.write!(state.file_path, content)
      {:noreply, %{state | last_content: content, skip_next_write: true}}
    else
      {:noreply, state}
    end
  end
end
