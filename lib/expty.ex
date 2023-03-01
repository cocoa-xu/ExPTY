defmodule ExPTY do
  @moduledoc """
  Documentation for `ExPTY`.
  """
  use GenServer

  defstruct [:pipesocket, :pid, :pty, :on_data, :on_exit]
  alias __MODULE__, as: T

  @spec default_pty_options() :: Keyword.t()
  def default_pty_options do
    [
      name: "xterm-color",
      cols: 80,
      rows: 24,
      env: System.get_env(),
      cwd: Path.expand("~"),
      encoding: "utf-8",
      handleFlowControl: false,
      flowControlPause: "\x13",
      flowControlResume: "\x11",
      on_data: nil,
      on_exit: nil
    ]
  end

  # APIs

  @spec spawn(String.t(), [String.t()], Keyword.t()) :: term()
  def spawn(file, args, pty_options \\ []) when is_binary(file) and is_list(args) and is_list(pty_options) do
    case GenServer.start(__MODULE__, {file, args, pty_options}) do
      {:ok, pty_pid} ->
        case GenServer.call(pty_pid, :do_spawn) do
          pty_pid when is_pid(pty_pid) ->
            pty_pid
          {:error, reason} ->
            {:error, reason}
          any ->
            {:error, any}
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec write(pid(), binary) :: :ok | {:partial, integer()} | {:error, String.t()}
  def write(pty, data) when is_binary(data) do
    GenServer.call(pty, {:write, data})
  end

  def on_data(pty, callback) when is_function(callback, 3) do
    GenServer.call(pty, {:update_on_data, {:func, callback}})
  end

  def on_data(pty, module) when is_atom(module) do
    if Kernel.function_exported?(module, :on_data, 3) do
      GenServer.call(pty, {:update_on_data, {:module, module}})
    else
      {:error, "expecting #{module}.on_data/3 to be exist"}
    end
  end

  def on_exit(pty, callback) when is_function(callback, 4) do
    GenServer.call(pty, {:update_on_exit, {:func, callback}})
  end

  def on_exit(pty, module) when is_atom(module) do
    if Kernel.function_exported?(module, :onExit, 4) do
      GenServer.call(pty, {:update_on_exit, {:module, module}})
    else
      {:error, "expecting #{module}.on_exit/3 to be exist"}
    end
  end

  def flow_control(pty, enable?) when is_boolean(enable?) do

  end

  # GenServer callbacks

  @impl true
  @spec init({String.t(), [String.t()], Keyword.t()}) :: {:ok, term()}
  def init(init_args) do
    {file, args, pty_options} = init_args

    # Initialize arguments
    file = file || "sh"
    args = args || []
    default_options = default_pty_options()
    options = Keyword.merge(default_options, pty_options)
    env = options[:env]
    cwd = options[:cwd]
    cols = options[:cols]
    rows = options[:rows]
    uid = options[:uid] || -1
    gid = options[:gid] || -1
    is_utf8 = options[:encoding] == "utf-8"
    closeFDs = options[:closeFDs] || false
    helperPath = ExPTY.Nif.helper_path()

    on_data = options[:on_data] || nil
    on_data =
      if is_function(on_data, 3) do
        {:func, on_data}
      else
      if is_atom(on_data) and Kernel.function_exported?(on_data, :on_data, 3) do
        {:module, on_data}
        else
          nil
        end
      end

    init_pack = {file, args, env, cwd, cols, rows, uid, gid, is_utf8, closeFDs, helperPath, on_data}
    {:ok, init_pack}
  end

  @impl true
  def handle_call(:do_spawn, _from, {file, args, env, cwd, cols, rows, uid, gid, is_utf8, closeFDs, helperPath, on_data}) do
    ret = ExPTY.Nif.spawn(file, args, env, cwd, cols, rows, uid, gid, is_utf8, closeFDs, helperPath)
    case ret do
      {pipesocket, pid, pty} when is_reference(pipesocket) and is_integer(pid) and is_binary(pty) ->
        {:reply, self(), %T{
          pipesocket: pipesocket,
          pid: pid,
          pty: pty,
          on_data: on_data
        }}
    end
  end

  @impl true
  def handle_call({:write, data}, _from, %T{pipesocket: pipesocket}=state) do
    ret = ExPTY.Nif.write(pipesocket, data)
    {:reply, ret, state}
  end

  @impl true
  def handle_call({:update_on_data, {:func, callback}}, _from, %T{}=state) do
    {:reply, :ok, %T{state | on_data: {:func, callback}}}
  end

  @impl true
  def handle_call({:update_on_data, {:module, module}}, _from, %T{}=state) do
    {:reply, :ok, %T{state | on_data: {:module, module}}}
  end

  @impl true
  def handle_call({:update_on_exit, {:func, callback}}, _from, %T{}=state) do
    {:reply, :ok, %T{state | on_exit: {:func, callback}}}
  end

  @impl true
  def handle_call({:update_on_exit, {:module, module}}, _from, %T{}=state) do
    {:reply, :ok, %T{state | on_exit: {:module, module}}}
  end

  @impl true
  def handle_info({:data, data}, %T{on_data: on_data}=state) do
    case on_data do
      {:module, module} ->
        module.on_data(__MODULE__, self(), data)
      {:func, func} ->
        func.(__MODULE__, self(), data)
      _ ->
        nil
    end
    {:noreply, state}
  end

  @impl true
  def handle_info({:exit, exit_code, signal_code}, %T{on_exit: on_exit}=state) do
    case on_exit do
      {:module, module} ->
        module.on_exit(__MODULE__, self(), exit_code, signal_code)
      {:func, func} ->
        func.(__MODULE__, self(), exit_code, signal_code)
      _ ->
        nil
    end
    {:noreply, state}
  end

  def resize(pty, columns, rows)
  when is_integer(columns) and columns > 0
  and is_integer(rows) and rows > 0 do

  end

  def pause(pty) do

  end

  def resume(pty) do

  end
end
