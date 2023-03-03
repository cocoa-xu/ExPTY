defmodule ExPTY.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    case :os.type() do
      {:win32, _} ->
        nil
      _ ->
        if Code.ensure_loaded?(Kino), do: Kino.SmartCell.register(ExPTY.SmartCell)
    end
    Supervisor.start_link([], strategy: :one_for_one)
  end
end
