defmodule ExPTY.MixProject do
  use Mix.Project

  @version "0.2.0"
  @github_url "https://github.com/cocoa-xu/expty"

  def project do
    [
      app: :expty,
      version: @version,
      elixir: "~> 1.12",
      name: "ExPTY",
      description: "`forkpty(3)` bindings for elixir",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_env: %{
        "MAKE_BUILD_FLAGS" =>
          System.get_env("MAKE_BUILD_FLAGS", "-j#{System.schedulers_online()}")
      },
      make_precompiler: {:nif, CCPrecompiler},
      make_precompiler_url: "#{@github_url}/releases/download/v#{@version}/@{artefact_filename}",
      make_precompiler_filename: "adbc_nif",
      make_precompiler_nif_versions: [versions: ["2.16"]],
      cc_precompiler: [
        cleanup: "clean",
      ]
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
        CMakeLists.txt
      ),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @github_url}
    ]
  end
end
