defmodule ExPTY.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    if Code.ensure_loaded?(Kino), do: Kino.SmartCell.register(ExPTY.SmartCell)
    Supervisor.start_link([], strategy: :one_for_one)
  end
end
