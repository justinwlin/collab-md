defmodule CollabCli.ChannelClient do
  use WebSockex

  @heartbeat_interval 30_000

  def start_link(opts) do
    url = opts[:url]
    state = %{
      topic: opts[:topic],
      username: opts[:username],
      ref: 0,
      join_ref: nil,
      callback_pid: opts[:callback_pid]
    }

    ws_url =
      url
      |> String.replace("http://", "ws://")
      |> String.replace("https://", "wss://")
      |> Kernel.<>("/socket/websocket?username=#{opts[:username]}")

    WebSockex.start_link(ws_url, __MODULE__, state)
  end

  def send_update(pid, document, author) do
    WebSockex.cast(pid, {:send_update, document, author})
  end

  @impl true
  def handle_connect(_conn, state) do
    ref = state.ref + 1

    join_msg =
      Jason.encode!(%{
        topic: state.topic,
        event: "phx_join",
        payload: %{username: state.username},
        ref: to_string(ref)
      })

    Process.send_after(self(), :heartbeat, @heartbeat_interval)
    {:reply, {:text, join_msg}, %{state | ref: ref, join_ref: to_string(ref)}}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    case Jason.decode!(msg) do
      %{"event" => "doc:state", "payload" => payload} ->
        send(state.callback_pid, {:doc_state, payload})
        {:ok, state}

      %{"event" => "doc:change", "payload" => payload} ->
        send(state.callback_pid, {:doc_change, payload})
        {:ok, state}

      %{"event" => "user:joined", "payload" => payload} ->
        send(state.callback_pid, {:user_joined, payload})
        {:ok, state}

      %{"event" => "user:left", "payload" => payload} ->
        send(state.callback_pid, {:user_left, payload})
        {:ok, state}

      %{"event" => "phx_reply", "payload" => %{"status" => "error", "response" => resp}} ->
        send(state.callback_pid, {:error, resp})
        {:ok, state}

      _ ->
        {:ok, state}
    end
  end

  @impl true
  def handle_cast({:send_update, document, author}, state) do
    ref = state.ref + 1

    msg =
      Jason.encode!(%{
        topic: state.topic,
        event: "doc:update",
        payload: %{document: document, author: author},
        ref: to_string(ref)
      })

    {:reply, {:text, msg}, %{state | ref: ref}}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    ref = state.ref + 1

    msg =
      Jason.encode!(%{
        topic: "phoenix",
        event: "heartbeat",
        payload: %{},
        ref: to_string(ref)
      })

    Process.send_after(self(), :heartbeat, @heartbeat_interval)
    {:reply, {:text, msg}, %{state | ref: ref}}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def handle_disconnect(_reason, state) do
    IO.puts("[collab] Disconnected. Reconnecting in 2s...")
    Process.sleep(2000)
    {:reconnect, state}
  end
end
