defmodule ExPTY do
  @moduledoc """
  Documentation for `ExPTY`.
  """
  use GenServer

  defstruct [
    :pipesocket,
    :pid,
    :pty,
    :handle_flow_control,
    :flow_control_pause,
    :flow_control_resume,
    :on_data,
    :on_exit
  ]

  alias __MODULE__, as: T

  @spec default_pty_options() :: Keyword.t()
  def default_pty_options do
    [
      name: Application.get_env(:expty, :name, "xterm-color"),
      cols: Application.get_env(:expty, :cols, 80),
      rows: Application.get_env(:expty, :rows, 24),
      env: Application.get_env(:expty, :env, System.get_env()),
      cwd: Application.get_env(:expty, :cwd, Path.expand("~")),
      encoding: Application.get_env(:expty, :encoding, "utf-8"),
      handle_flow_control: Application.get_env(:expty, :handle_flow_control, false),
      flow_control_pause: Application.get_env(:expty, :flow_control_pause, "\x13"),
      flow_control_resume: Application.get_env(:expty, :flow_control_resume, "\x11"),
      on_data: nil,
      on_exit: nil
    ]
  end

  # APIs

  @spec spawn(String.t(), [String.t()], Keyword.t()) :: {:ok, pid()} | {:error, String.t()}
  def spawn(file, args, pty_options \\ [])
      when is_binary(file) and is_list(args) and is_list(pty_options) do
    case GenServer.start(__MODULE__, {file, args, pty_options}) do
      {:ok, pty_pid} ->
        case GenServer.call(pty_pid, :do_spawn) do
          pty_pid when is_pid(pty_pid) ->
            {:ok, pty_pid}

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

  @spec kill(pid, integer) :: :ok
  def kill(pty, signal) when is_integer(signal) do
    GenServer.call(pty, {:kill, signal})
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

  @spec resize(pid(), pos_integer, pos_integer) :: :ok | {:error, String.t()}
  def resize(pty, cols, rows)
      when is_integer(cols) and cols > 0 and
             is_integer(rows) and rows > 0 do
    GenServer.call(pty, {:resize, {cols, rows}})
  end

  @spec flow_control(pid) :: boolean()
  def flow_control(pty) when is_pid(pty) do
    GenServer.call(pty, :flow_control)
  end

  @spec flow_control(pid, boolean) :: :ok
  def flow_control(pty, enable?) when is_pid(pty) and is_boolean(enable?) do
    GenServer.call(pty, {:flow_control, enable?})
  end

  @spec pause(pid) :: :ok
  def pause(pty) do
    GenServer.call(pty, :pause)
  end

  @spec resume(pid) :: :ok
  def resume(pty) do
    GenServer.call(pty, :resume)
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

    handle_flow_control = options[:handle_flow_control] || false

    handle_flow_control =
      if is_boolean(handle_flow_control) do
        handle_flow_control
      else
        raise "value of `handle_flow_control` should be a boolean"
      end

    flow_control_pause = options[:flow_control_pause] || "\x13"

    flow_control_pause =
      if is_binary(flow_control_pause) do
        flow_control_pause
      else
        raise "value of `flow_control_pause` should be a binary string"
      end

    flow_control_resume = options[:flow_control_resume] || "\x11"

    flow_control_resume =
      if is_binary(flow_control_resume) do
        flow_control_resume
      else
        raise "value of `flow_control_resume` should be a binary string"
      end

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

    on_exit = options[:on_exit] || nil

    on_exit =
      if is_function(on_exit, 4) do
        {:func, on_exit}
      else
        if is_atom(on_exit) and Kernel.function_exported?(on_exit, :on_exit, 3) do
          {:module, on_exit}
        else
          nil
        end
      end

    init_pack = {
      file,
      args,
      env,
      cwd,
      cols,
      rows,
      uid,
      gid,
      is_utf8,
      closeFDs,
      helperPath,
      handle_flow_control,
      flow_control_pause,
      flow_control_resume,
      on_data,
      on_exit
    }

    {:ok, init_pack}
  end

  @impl true
  def handle_call(
        :do_spawn,
        _from,
        {file, args, env, cwd, cols, rows, uid, gid, is_utf8, closeFDs, helperPath,
         handle_flow_control, flow_control_pause, flow_control_resume, on_data, on_exit}
      ) do
    ret =
      ExPTY.Nif.spawn(file, args, env, cwd, cols, rows, uid, gid, is_utf8, closeFDs, helperPath)

    case ret do
      {pipesocket, pid, pty}
      when is_reference(pipesocket) and is_integer(pid) and is_binary(pty) ->
        {:reply, self(),
         %T{
           pipesocket: pipesocket,
           pid: pid,
           pty: pty,
           handle_flow_control: handle_flow_control,
           flow_control_pause: flow_control_pause,
           flow_control_resume: flow_control_resume,
           on_data: on_data,
           on_exit: on_exit
         }}
    end
  end

  @impl true
  def handle_call(
        {:write, data},
        _from,
        %T{
          pipesocket: pipesocket,
          handle_flow_control: handle_flow_control,
          flow_control_pause: flow_control_pause,
          flow_control_resume: flow_control_resume
        } = state
      ) do
    if handle_flow_control do
      case data do
        ^flow_control_pause ->
          ExPTY.Nif.pause(pipesocket)

        ^flow_control_resume ->
          ExPTY.Nif.resume(pipesocket)

        _ ->
          :ok
      end

      {:reply, :ok, state}
    else
      ret = ExPTY.Nif.write(pipesocket, data)
      {:reply, ret, state}
    end
  end

  @impl true
  def handle_call({:kill, signal}, _from, %T{pipesocket: pipesocket} = state)
      when is_integer(signal) do
    ret = ExPTY.Nif.kill(pipesocket, signal)
    {:reply, ret, state}
  end

  @impl true
  def handle_call({:update_on_data, {:func, callback}}, _from, %T{} = state) do
    {:reply, :ok, %T{state | on_data: {:func, callback}}}
  end

  @impl true
  def handle_call({:update_on_data, {:module, module}}, _from, %T{} = state) do
    {:reply, :ok, %T{state | on_data: {:module, module}}}
  end

  @impl true
  def handle_call({:update_on_exit, {:func, callback}}, _from, %T{} = state) do
    {:reply, :ok, %T{state | on_exit: {:func, callback}}}
  end

  @impl true
  def handle_call({:update_on_exit, {:module, module}}, _from, %T{} = state) do
    {:reply, :ok, %T{state | on_exit: {:module, module}}}
  end

  @impl true
  def handle_call({:resize, {cols, rows}}, _from, %T{pipesocket: pipesocket} = state) do
    ret = ExPTY.Nif.resize(pipesocket, cols, rows)
    {:reply, ret, state}
  end

  @impl true
  def handle_call(:flow_control, _from, %T{handle_flow_control: handle_flow_control} = state) do
    {:reply, handle_flow_control, state}
  end

  @impl true
  def handle_call(
        {:flow_control, enable?},
        _from,
        %T{pipesocket: pipesocket, handle_flow_control: handle_flow_control} = state
      ) do
    if !enable? and handle_flow_control do
      ExPTY.Nif.resume(pipesocket)
    end

    {:reply, :ok, %T{state | handle_flow_control: enable?}}
  end

  @impl true
  def handle_call(:pause, _from, %T{pipesocket: pipesocket} = state) do
    ret = ExPTY.Nif.pause(pipesocket)
    {:reply, ret, state}
  end

  @impl true
  def handle_call(:resume, _from, %T{pipesocket: pipesocket} = state) do
    ret = ExPTY.Nif.resume(pipesocket)
    {:reply, ret, state}
  end

  @impl true
  def handle_info({:data, data}, %T{on_data: on_data} = state) do
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
  def handle_info({:exit, exit_code, signal_code}, %T{on_exit: on_exit} = state) do
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
end
