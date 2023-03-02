defmodule ExPTY.MixProject do
  use Mix.Project

  @version "0.1.0"
  @github_url "https://github.com/cocoa-xu/expty"

  def project do
    [
      app: :expty,
      version: "0.1.0",
      elixir: "~> 1.12",
      name: "ExPTY",
      description: "`forkpty(3)` bindings for elixir",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      compilers: [:elixir_make] ++ Mix.compilers()
    ]
  end

  def application do
    [
      mod: {ExPTY.Application, []}
    ]
  end

  defp deps do
    [
      {:elixir_make, "~> 0.7", runtime: false},
      {:cc_precompiler, "~> 0.1", runtime: false},
      {:kino, "~> 0.7", optional: true}
    ]
  end

  defp docs do
    [
      main: "ExPTY",
      source_ref: "v#{@version}",
      source_url: @github_url
    ]
  end

  defp package() do
    [
      name: "ExPTY",
      files: ~w(
        c_src
        3rd_party
        lib
        mix.exs
        README*
        LICENSE*
        Makefile
      ),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @github_url}
    ]
  end
end
