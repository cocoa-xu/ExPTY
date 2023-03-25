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
    case :os.type() do
      {:win32, _} ->
        nil

      _ ->
        "#{:code.priv_dir(:expty)}/spawn-helper"
    end
  end

  case :os.type() do
    {:win32, _} ->
      def spawn(_file, _cols, _rows, _debug, _pipe_name, _inherit_cursor),
        do: :erlang.nif_error(:not_loaded)

      def write(_pty, _data),
        do: :erlang.nif_error(:not_loaded)

      def resize(_pty_id, _cols, _rows),
        do: :erlang.nif_error(:not_loaded)

      def priv_connect(_pty_id, _command_line, _cwd, _env),
        do: :erlang.nif_error(:not_loaded)

    _ ->
      def spawn(
            _file,
            _args,
            _env,
            _cwd,
            _cols,
            _rows,
            _uid,
            _gid,
            _is_utf8,
            _closeFDs,
            _helperPath
          ),
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
end
