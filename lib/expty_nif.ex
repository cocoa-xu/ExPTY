defmodule ExPTY.Nif do
  @moduledoc false

  @on_load :load_nif
  def load_nif do
    nif_file = ~c"#{:code.priv_dir(:expty)}/expty"

    case :erlang.load_nif(nif_file, 0) do
      :ok -> :ok
      {:error, {:reload, _}} -> :ok
      {:error, reason} -> IO.puts("Failed to load nif: #{reason}")
    end
  end

  def helper_path do
    helper_path = "#{:code.priv_dir(:expty)}/spawn-helper"

    case :os.type() do
      {:win32, _} ->
        helper_path <> ".exe"

      _ ->
        helper_path
    end
  end

  def spawn(_file, _args, _env, _cwd, _cols, _rows, _uid, _gid, _is_utf8, _closeFDs, _helperPath),
    do: :erlang.nif_error(:not_loaded)

  def write(_pipesocket, _data),
    do: :erlang.nif_error(:not_loaded)

  def kill(_pipesocket, _signal),
    do: :erlang.nif_error(:not_loaded)

  def resize(_pipesocket, _cols, _rows),
    do: :erlang.nif_error(:not_loaded)

  def pause(_pipesocket),
    do: :erlang.nif_error(:not_loaded)

  def resume(_pipesocket),
    do: :erlang.nif_error(:not_loaded)
end
