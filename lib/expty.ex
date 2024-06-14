defmodule ExPTY do
  @moduledoc """
  `forkpty(3)` bindings for Elixir.

  This allows you to fork processes with pseudoterminal file descriptors.

  It returns a terminal genserver which allows reads and writes.
  """

  use GenServer

  defstruct [
    # common
    :os_type,
    :pid,
    :pty,
    :on_data,
    :on_exit,

    # unix
    :pipesocket,
    :handle_flow_control,
    :flow_control_pause,
    :flow_control_resume,

    # windows
    :conin,
    :conout,
    :inner_pid
  ]

  alias __MODULE__, as: T

  @doc """
  Default options when spawning a process.

  Please see `ExPTY.spawn/3` for details.
  """
  @spec default_pty_options() :: Keyword.t()
  def default_pty_options do
    default_pty_options_impl(:os.type())
  end

  defp default_pty_options_impl({:unix, _}) do
    [
      name: Application.get_env(:expty, :name, "xterm-color"),
      cols: Application.get_env(:expty, :cols, 80),
      rows: Application.get_env(:expty, :rows, 24),
      ibaudrate: 38400,
      obaudrate: 38400,
      env: Application.get_env(:expty, :env, System.get_env()),
      cwd: Application.get_env(:expty, :cwd, Path.expand("~")),
      on_data: nil,
      on_exit: nil,
      encoding: Application.get_env(:expty, :encoding, "utf-8"),
      handle_flow_control: Application.get_env(:expty, :handle_flow_control, false),
      flow_control_pause: Application.get_env(:expty, :flow_control_pause, "\x13"),
      flow_control_resume: Application.get_env(:expty, :flow_control_resume, "\x11")
    ]
  end

  defp default_pty_options_impl({:win32, _}) do
    [
      name: Application.get_env(:expty, :name, "Windows Shell"),
      cols: Application.get_env(:expty, :cols, 80),
      rows: Application.get_env(:expty, :rows, 24),
      env: Application.get_env(:expty, :env, System.get_env()),
      cwd: Application.get_env(:expty, :cwd, Path.expand("~")),
      on_data: nil,
      on_exit: nil,
      debug: Application.get_env(:expty, :debug, false),
      pipe_name: Application.get_env(:expty, :pipe_name, "pipe"),
      inherit_cursor: Application.get_env(:expty, :inherit_cursor, false)
    ]
  end

  @doc """
  Forks a process as a pseudoterminal.

  ##### Positional Paramters
  - `file`: `String.t()`

    The file to launch.

  - `args`: `list(String.t())`

    The file's arguments as argv (const char * []).

  ##### Keyword Parameters
  ##### Common Keyword Parameters (Unix & Windows)
  - `name`: `String.t()`

    Terminal name.

    Defaults to `xterm-color` on Unix systems and `Windows Shell` on Windows.

  - `cols`: `pos_integer()`

    Number of columns.

    Defaults to 80.

  - `rows`: `pos_integer()`

    Number of rows.

    Defaults to 24.

  - `ibaudrate`: `non_neg_integer()`

    `cfsetispeed(term, ibaudrate)`

    Defaults to 38400.

  - `obaudrate`: `non_neg_integer()`

    `cfsetospeed(term, obaudrate)`

    Defaults to 38400.

  - `env`: `%{String.t() => String.t()}`

    Environment variables.

    Defaults to `System.get_env()`.

    Notice, as the default value is given by `System.get_env()`, therefore, please be careful of leaking
    secrets set in the environment.

  - `cwd`: `String.t()`

    Current working directory.

    Defaults to `Path.expand("~")`.

  - `on_data`: `(ExPTY, pid(), binary() -> term()) | atom`

    Callback when data is available.

    Defaults to `nil`.

    When passing a function, the function should expect 3 arguments,

      1. `ExPTY`: The module name of `ExPTY`. This will probably be removed in the first release.
      2. `pid()`: The genserver pid so that you can reuse the same function for different processes spawned.
      3. `binary()`: The data read from the spawned process.

    When passing a module name, the module should export an `on_data/3` function,
    this function should expect the same arguments as mentioned above.

    The return value of this callback function is ignored.

  - `on_exit`: `(ExPTY, pid(), integer(), integer() | nil -> term()) | atom`

    Callback when the spawned process exited.

    Defaults to `nil`.

    When passing a function, the function should expect 4 arguments,

      1. `ExPTY`: The module name of `ExPTY`. This will probably be removed in the first release.
      2. `pid()`: The genserver pid so that you can reuse the same function for different processes spawned.
      3. `integer()`: The exit code the spawned process.
      4. `integer() | nil`: On unix, this is the signal code from the spawned process. On Windows, this value
        is `nil`.

    When passing a module name, the module should export an `on_data/3` function,
    this function should expect the same arguments as mentioned above.

    The return value of this callback function is ignored.

  ##### Unix-specific Keyword Parameters
  - `encoding`: `String.t()`

    Defaults to `utf-8`. This keyword parameter will probably be removed in the first release.

  - `handle_flow_control`: `boolean()`

    Defaults to `false`.

    Toggle flow control.

  - `flow_control_pause`: `binary()`

    Default messages to indicate PAUSE for automatic flow control.

    Customisble to avoid conflicts with rebound XON/XOFF control codes (such as on-my-zsh),

    Defaults to `\x13`, i.e, `XOFF`.

  - `flow_control_resume`: `binary()`

    Default messages to indicate RESUME for automatic flow control.

    Customisble to avoid conflicts with rebound XON/XOFF control codes (such as on-my-zsh),

    Defaults to `\x11`, i.e, `XON`.

  ##### Windows-specific Keyword Parameters
  - `debug`: `boolean()`

    Defaults to `false`. This keyword parameter is not used when the backend is conpty, i.e., when
    Windows version >= 1809.

  - `pipe_name`: `String.t()`

    Prefix of the pipe name.

    Defaults to `"pipe"`.

  - `inherit_cursor`: `boolean()`

    Whether to use PSEUDOCONSOLE_INHERIT_CURSOR in conpty.

    See docs on [createpseudoconsole](https://docs.microsoft.com/en-us/windows/console/createpseudoconsole).

    Defaults to `false`.
  """
  @spec spawn(String.t(), [String.t()], keyword) :: {:ok, pid} | {:error, String.t()}
  def spawn(file, args, opts \\ []) do
    case GenServer.start(__MODULE__, {file, args, opts}) do
      {:ok, pid} ->
        case GenServer.call(pid, :do_spawn) do
          :ok ->
            {:ok, pid}

          error ->
            error
        end

      error ->
        error
    end
  end

  @doc """
  Write data to the pseudoterminal.
  """
  @spec write(pid, binary) :: :ok | {:error, String.t()} | {:partial, integer}
  def write(pty, data) do
    GenServer.call(pty, {:write, data})
  end

  @doc """
  Kill the process with given signal.
  """
  @spec kill(pid, integer) :: :ok
  def kill(pty, signal) when is_integer(signal) do
    GenServer.call(pty, {:kill, signal})
  end

  @doc """
  Set callback function or module when data is available from the pseudoterminal.
  """
  @spec on_data(pid(), atom | (ExPTY, pid(), binary() -> any)) :: :ok
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

  @doc """
  Set callback function or module when the process exited.
  """
  @spec on_exit(pid(), atom() | (ExPTY, pid(), integer(), integer() | nil -> any)) :: :ok
  def on_exit(pty, callback) when is_function(callback, 4) do
    GenServer.call(pty, {:update_on_exit, {:func, callback}})
  end

  def on_exit(pty, module) when is_atom(module) do
    if Kernel.function_exported?(module, :on_exit, 4) do
      GenServer.call(pty, {:update_on_exit, {:module, module}})
    else
      {:error, "expecting #{module}.on_exit/3 to be exist"}
    end
  end

  @doc """
  Resize the pseudoterminal.
  """
  @spec resize(pid, pos_integer, pos_integer) :: :ok | {:error, String.t()}
  def resize(pty, cols, rows)
      when is_pid(pty) and is_integer(cols) and cols > 0 and is_integer(rows) and rows > 0 do
    GenServer.call(pty, {:resize, {cols, rows}})
  end

  @doc """
  Get flow control status (only available on Unix systems at the moment).
  """
  @spec flow_control(pid) :: boolean()
  def flow_control(pty) when is_pid(pty) do
    GenServer.call(pty, :flow_control)
  end

  @doc """
  Set flow control status (only available on Unix systems at the moment).
  """
  @spec flow_control(pid, boolean) :: :ok
  def flow_control(pty, enable?) when is_pid(pty) and is_boolean(enable?) do
    GenServer.call(pty, {:flow_control, enable?})
  end

  @doc """
  Pause flow (only available on Unix systems at the moment).
  """
  @spec pause(pid) :: :ok
  def pause(pty) when is_pid(pty) do
    GenServer.call(pty, :pause)
  end

  @doc """
  Resume flow (only available on Unix systems at the moment).
  """
  @spec resume(pid) :: :ok
  def resume(pty) when is_pid(pty) do
    GenServer.call(pty, :resume)
  end

  # GenServer callbacks

  @impl true
  @spec init({String.t(), [String.t()], Keyword.t()}) :: {:ok, term()}
  def init(init_args) do
    {file, args, pty_options} = init_args

    # Initialize arguments
    default_options = default_pty_options()
    options = Keyword.merge(default_options, pty_options)
    args = args || []
    env = options[:env]
    cwd = Path.expand(options[:cwd])
    cols = options[:cols]
    rows = options[:rows]

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

    init_pack =
      case :os.type() do
        {os_type = :unix, _} ->
          file = file || "sh"
          ibaudrate = options[:ibaudrate] || 38400
          obaudrate = options[:obaudrate] || 38400
          uid = options[:uid] || -2
          gid = options[:gid] || -2
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

          {
            os_type,
            file,
            args,
            env,
            cwd,
            cols,
            rows,
            ibaudrate,
            obaudrate,
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

        {os_type = :win32, _} ->
          # win
          file = file || "powershell.exe"
          debug = options[:debug] || false
          pipe_name = options[:pipe_name] || "pipe"
          pipe_name = "#{pipe_name}-#{:rand.uniform(100_000_000)}"
          inherit_cursor = options[:inherit_cursor] || false

          {
            os_type,
            file,
            args,
            env,
            cwd,
            cols,
            rows,
            debug,
            pipe_name,
            inherit_cursor,
            on_data,
            on_exit
          }
      end

    {:ok, init_pack}
  end

  @impl true
  def handle_call(
        :do_spawn,
        _from,
        {os_type = :unix, file, args, env, cwd, cols, rows, ibaudrate, obaudrate, uid, gid, is_utf8, closeFDs,
         helperPath, handle_flow_control, flow_control_pause, flow_control_resume, on_data,
         on_exit}
      ) do
    ret =
      ExPTY.Nif.spawn_unix(
        file,
        args,
        env,
        cwd,
        cols,
        rows,
        ibaudrate,
        obaudrate,
        uid,
        gid,
        is_utf8,
        closeFDs,
        helperPath
      )

    case ret do
      {pipesocket, pid, pty}
      when is_reference(pipesocket) and is_integer(pid) and is_binary(pty) ->
        {:reply, :ok,
         %T{
           os_type: os_type,
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
        :do_spawn,
        _from,
        state =
          {os_type = :win32, file, args, env, cwd, cols, rows, debug, pipe_name, inherit_cursor,
           on_data, on_exit}
      ) do
    case ExPTY.Nif.spawn_win32(file, cols, rows, debug, pipe_name, inherit_cursor) do
      {pty_id, conin, conout} when is_integer(pty_id) ->
        command_line = args_to_command_line(file, args)

        case ExPTY.Nif.connect_win32(pty_id, command_line, cwd, env) do
          {:ok, inner_pid} ->
            {:reply, :ok,
             %T{
               os_type: os_type,
               pty: pty_id,
               conin: conin,
               conout: conout,
               inner_pid: inner_pid,
               on_data: on_data,
               on_exit: on_exit
             }}

          error ->
            {:reply, error, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(
        {:write, data},
        _from,
        %T{
          os_type: :unix,
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
  def handle_call({:write, data}, _from, %T{os_type: :win32, pty: pty} = state) do
    {:reply, ExPTY.Nif.write(pty, data), state}
  end

  @impl true
  def handle_call({:kill, signal}, _from, %T{os_type: :unix, pipesocket: pipesocket} = state)
      when is_integer(signal) do
    ret = ExPTY.Nif.kill(pipesocket, signal)
    {:reply, ret, state}
  end

  @impl true
  def handle_call({:kill, signal}, _from, %T{os_type: :win32} = state) when is_integer(signal) do
    # ret = ExPTY.Nif.kill(pipesocket, signal)
    # TODO: implement kill/2 on windows
    {:reply, :not_implemented_yet, state}
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
  def handle_call(
        {:resize, {cols, rows}},
        _from,
        %T{os_type: :unix, pipesocket: pipesocket} = state
      ) do
    ret = ExPTY.Nif.resize(pipesocket, cols, rows)
    {:reply, ret, state}
  end

  @impl true
  def handle_call({:resize, {cols, rows}}, _from, %T{os_type: :win32, pty: pty} = state) do
    ret = ExPTY.Nif.resize(pty, cols, rows)
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

  @doc """
  Convert argc/argv into a Win32 command-line following the escaping convention
  documented on MSDN (e.g. see CommandLineToArgvW documentation). Copied from
  winpty and node-pty project.
  """
  def args_to_command_line(file, args) do
    argv = [file | args]
    args_to_command_line_impl(argv, 0, "")
  end

  defp args_to_command_line_impl([], _index, result), do: result

  defp args_to_command_line_impl([arg | argv], index, result) when is_binary(arg) do
    result =
      if index > 0 do
        "#{result} "
      else
        result
      end

    arg0 = String.at(arg, 0)
    has_lopsided_enclosing_quote = xor(arg0 != "\"", !String.ends_with?(arg, "\""))
    has_no_eclosing_quotes = arg0 != "\"" && !String.ends_with?(arg, "\"")

    quote? =
      arg == "" ||
        ((:binary.match(arg, " ") != :nomatch || :binary.match(arg, "\t") != :nomatch) &&
           (String.length(arg) > 0 && (has_lopsided_enclosing_quote || has_no_eclosing_quotes)))

    result =
      if quote? do
        "#{result}\""
      else
        result
      end

    bs_count = 0

    {bs_count, result} =
      Enum.reduce(0..(String.length(arg) - 1), {bs_count, result}, fn index,
                                                                      {bs_count_, result_} ->
        case String.at(arg, index) do
          "\\" ->
            {bs_count_ + 1, result_}

          "\"" ->
            result_ = "#{result_}#{repeat_text("\\", bs_count_ * 2 + 1)}\""
            {0, result_}

          p ->
            result_ = "#{result_}#{repeat_text("\\", bs_count_)}#{p}"
            {0, result_}
        end
      end)

    result =
      if quote? do
        "#{result}#{repeat_text("\\", bs_count * 2)}\""
      else
        "#{result}#{repeat_text("\\", bs_count)}"
      end

    args_to_command_line_impl(argv, index + 1, result)
  end

  defp repeat_text(_text, count) when count < 0 do
    ""
  end

  defp repeat_text(text, count) when count >= 0 do
    repeat_text_impl(text, count, [])
  end

  defp repeat_text_impl(_text, count, result) when count <= 0 do
    IO.iodata_to_binary(result)
  end

  defp repeat_text_impl(text, count, result) when count > 0 do
    repeat_text_impl(text, count - 1, [text | result])
  end

  defp xor(a, b) when is_boolean(a) and is_boolean(b) do
    (a && !b) || (!a && b)
  end
end
