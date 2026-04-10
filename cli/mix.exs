defmodule CollabCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :collab_cli,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [main_module: CollabCli]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:websockex, "~> 0.4.3"},
      {:jason, "~> 1.4"},
      {:file_system, "~> 1.0"},
      {:req, "~> 0.5"}
    ]
  end
end
