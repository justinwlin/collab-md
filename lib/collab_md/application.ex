defmodule CollabMd.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CollabMdWeb.Telemetry,
      CollabMd.RateLimiter,
      {Registry, keys: :unique, name: CollabMd.RoomRegistry},
      {CollabMd.RoomSupervisor, []},
      {Phoenix.PubSub, name: CollabMd.PubSub},
      CollabMdWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CollabMd.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CollabMdWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
