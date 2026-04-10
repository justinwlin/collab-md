defmodule CollabCli do
  def main(args) do
    Application.ensure_all_started(:req)

    case args do
      ["create" | rest] -> cmd_create(rest)
      ["join", code | rest] -> cmd_join(code, rest)
      ["history", code] -> cmd_history(code)
      ["restore", code, version] -> cmd_restore(code, version)
      ["status", code] -> cmd_status(code)
      _ -> usage()
    end
  end

  defp server_url do
    System.get_env("COLLAB_SERVER") || "https://collab-md.fly.dev"
  end

  defp parse_opts(args, defaults \\ %{}) do
    args
    |> Enum.chunk_every(2)
    |> Enum.reduce(defaults, fn
      ["--name", name], acc -> Map.put(acc, :name, name)
      ["--file", file], acc -> Map.put(acc, :file, file)
      ["--server", url], acc -> Map.put(acc, :server, url)
      _, acc -> acc
    end)
  end

  defp cmd_create(rest) do
    opts = parse_opts(rest, %{name: System.get_env("USER", "anonymous")})

    case Req.post("#{server_url()}/api/rooms") do
      {:ok, %{status: 201, body: %{"code" => code}}} ->
        IO.puts("Room created: #{code}")
        IO.puts("Share this code: collab join #{code} --name <name>")
        IO.puts("")
        cmd_join(code, ["--name", opts.name])

      {:error, reason} ->
        IO.puts("Error creating room: #{inspect(reason)}")
    end
  end

  defp cmd_join(code, rest) do
    opts = parse_opts(rest, %{name: System.get_env("USER", "anonymous")})
    file_path = Path.absname(Map.get(opts, :file, "collab-#{code}.md"))

    IO.puts("Joining room #{code} as #{opts.name}...")
    IO.puts("Syncing to: #{file_path}")
    IO.puts("Edit the file with any editor. Changes sync automatically.")
    IO.puts("Press Ctrl+C to leave.\n")

    {:ok, channel_pid} =
      CollabCli.ChannelClient.start_link(%{
        url: server_url(),
        topic: "room:#{code}",
        username: opts.name,
        callback_pid: self()
      })

    # Wait for initial state
    initial_content =
      receive do
        {:doc_state, %{"document" => doc}} ->
          IO.puts("[collab] Connected!")
          doc

        {:error, reason} ->
          IO.puts("[collab] Error: #{inspect(reason)}")
          System.halt(1)
      after
        10_000 ->
          IO.puts("[collab] Timeout connecting to room.")
          System.halt(1)
      end

    {:ok, _sync_pid} =
      CollabCli.Sync.start_link(%{
        file_path: file_path,
        username: opts.name,
        channel_pid: channel_pid,
        initial_content: initial_content
      })

    listen_loop()
  end

  defp listen_loop do
    receive do
      {:doc_change, %{"document" => content, "author" => author, "version" => version}} ->
        IO.puts("[collab] Update from #{author} (v#{version})")
        CollabCli.Sync.remote_update(content)
        listen_loop()

      {:user_joined, %{"username" => name, "users" => users}} ->
        IO.puts("[collab] #{name} joined (online: #{Enum.join(users, ", ")})")
        listen_loop()

      {:user_left, %{"username" => name, "users" => users}} ->
        IO.puts("[collab] #{name} left (online: #{Enum.join(users, ", ")})")
        listen_loop()

      {:doc_state, %{"document" => content}} ->
        CollabCli.Sync.remote_update(content)
        listen_loop()

      {:error, reason} ->
        IO.puts("[collab] Error: #{inspect(reason)}")
        listen_loop()
    end
  end

  defp cmd_history(code) do
    case Req.get("#{server_url()}/api/rooms/#{code}/versions") do
      {:ok, %{status: 200, body: %{"versions" => versions}}} ->
        if versions == [] do
          IO.puts("No versions yet.")
        else
          IO.puts("Version history for room #{code}:\n")

          Enum.each(versions, fn v ->
            IO.puts("  v#{v["number"]}  by #{v["author"]}  at #{v["timestamp"]}")
          end)
        end

      {:ok, %{status: 404}} ->
        IO.puts("Room #{code} not found.")

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
    end
  end

  defp cmd_restore(code, version) do
    case Req.put("#{server_url()}/api/rooms/#{code}/restore/#{version}") do
      {:ok, %{status: 200, body: %{"document" => doc}}} ->
        IO.puts("Restored to version #{version}. Document:\n")
        IO.puts(doc)

      {:ok, %{status: 404}} ->
        IO.puts("Room or version not found.")

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
    end
  end

  defp cmd_status(code) do
    case Req.get("#{server_url()}/api/rooms/#{code}/status") do
      {:ok, %{status: 200, body: status}} ->
        IO.puts("Room: #{code}")
        IO.puts("Version: #{status["version"]}")
        IO.puts("Online: #{Enum.join(status["users"], ", ")}")

      {:ok, %{status: 404}} ->
        IO.puts("Room #{code} not found.")

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
    end
  end

  defp usage do
    IO.puts("""
    CollabMd CLI - Live collaborative markdown editing

    Commands:
      collab create [options]            Create a new room and start syncing
      collab join CODE [options]         Join an existing room
      collab history CODE                Show version history (snapshots)
      collab restore CODE VERSION        Restore a previous version
      collab status CODE                 Show room status and who's online

    Options:
      --name NAME      Your display name (default: $USER)
      --file PATH      Path to a local markdown file (default: ./collab-CODE.md)

    Environment:
      COLLAB_SERVER    Server URL (default: https://collab-md.fly.dev)

    How it works:
      When you create or join a room, a local markdown file is created (or linked
      via --file). Any edits you make to that file are synced to everyone in the
      room in real-time. You can use any editor — VS Code, vim, nano, etc.

      Every save creates an automatic version snapshot. Use 'history' to see all
      versions and 'restore' to roll back. Snapshots are ephemeral — they are
      discarded when the room closes (4hr idle or 30min after last person leaves).

    Using --file with an existing markdown file:
      You can point --file at an existing .md file. On join, the server's current
      document overwrites the local file (it does not merge). So if you want to
      seed a room with your existing content, use 'create' with --file — your
      first save will upload it to the room for others to see.

    Examples:
      collab create --name alice                     # Create room, sync to ./collab-CODE.md
      collab create --name alice --file notes.md     # Create room, sync to existing file
      collab join abc123 --name bob                  # Join room, sync to ./collab-abc123.md
      collab join abc123 --name bob --file notes.md  # Join room, sync to specific file
      collab history abc123                          # List all version snapshots
      collab restore abc123 2                        # Roll back to version 2

    Programmatic access (curl, Claude Code, scripts):
      curl https://collab-md.fly.dev/api/rooms/CODE/document
      curl -X PUT https://collab-md.fly.dev/api/rooms/CODE/document \\
        -H 'Content-Type: application/json' \\
        -d '{"document": "# content", "author": "claude"}'
    """)
  end
end
