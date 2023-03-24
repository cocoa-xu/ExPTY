defmodule ExPTY do
  @spec spawn(binary, [binary], keyword) :: {:error, String.t()} | {:ok, pid}
  def spawn(file, args, opts \\ []) do
    spawn_impl(:os.type(), file, args, opts)
  end

  defp spawn_impl({:unix, _}, file, args, opts) do
    ExPTY.Unix.spawn(file, args, opts)
  end

  defp spawn_impl({:win32, _}, file, args, opts) do
    ExPTY.Win.spawn(file, args, opts)
  end

  @spec write(pid, binary) :: :ok | {:error, String.t()} | {:partial, integer}
  def write(pty, data) do
    write_impl(:os.type(), pty, data)
  end

  defp write_impl({:unix, _}, pty, data) do
    ExPTY.Unix.write(pty, data)
  end

  defp write_impl({:win32, _}, pty, data) do
    ExPTY.Win.write(pty, data)
  end

  @spec kill(pid, integer) :: :ok
  def kill(pty, signal) when is_integer(signal) do
    kill_impl(:os.type(), pty, signal)
  end

  defp kill_impl({:unix, _}, pty, signal) do
    ExPTY.Unix.kill(pty, signal)
  end

  defp kill_impl({:win32, _}, pty, signal) do
    ExPTY.Win.kill(pty, signal)
  end

  @spec on_data(pid(), atom | (ExPTY, pid(), binary() -> any)) :: :ok
  def on_data(pty, callback) do
    on_data_impl(:os.type(), pty, callback)
  end

  defp on_data_impl({:unix, _}, pty, callback) do
    ExPTY.Unix.on_data(pty, callback)
  end

  defp on_data_impl({:win32, _}, pty, callback) do
    ExPTY.Win.on_data(pty, callback)
  end

  @spec on_exit(pid(), atom() | (ExPTY, pid(), integer(), integer() | nil -> any)) :: :ok
  def on_exit(pty, callback) do
    on_exit_impl(:os.type(), pty, callback)
  end

  defp on_exit_impl({:unix, _}, pty, callback) do
    ExPTY.Unix.on_exit(pty, callback)
  end

  defp on_exit_impl({:win32, _}, pty, callback) do
    ExPTY.Win.on_exit(pty, callback)
  end

  @spec resize(pid, pos_integer, pos_integer) :: :ok | {:error, String.t()}
  def resize(pty, cols, rows) do
    resize_impl(:os.type(), pty, cols, rows)
  end

  defp resize_impl({:unix, _}, pty, cols, rows) do
    ExPTY.Unix.resize(pty, cols, rows)
  end

  defp resize_impl({:win32, _}, pty, cols, rows) do
    ExPTY.Win.resize(pty, cols, rows)
  end
end
