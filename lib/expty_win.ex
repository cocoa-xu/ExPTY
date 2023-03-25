case :os.type() do
  {:win32, _} ->
    defmodule ExPTY.Win do
      use GenServer

      defstruct [:pty, :conin, :conout, :inner_pid, :on_data, :on_exit]
      alias __MODULE__, as: T

      @spec default_pty_options() :: Keyword.t()
      def default_pty_options do
        [
          name: Application.get_env(:expty, :name, "Windows Shell"),
          file: Application.get_env(:expty, :file, "powershell.exe"),
          cols: Application.get_env(:expty, :cols, 80),
          rows: Application.get_env(:expty, :rows, 24),
          debug: Application.get_env(:expty, :debug, false),
          pipe_name: Application.get_env(:expty, :pipe_name, "pipe"),
          inherit_cursor: Application.get_env(:expty, :inherit_cursor, false),
          env: Application.get_env(:expty, :env, System.get_env()),
          cwd: Application.get_env(:expty, :cwd, Path.expand("~")),
          on_data: nil,
          on_exit: nil
        ]
      end

      @spec spawn(String.t(), [String.t()], Keyword.t()) :: term()
      def spawn(file, args, pty_options \\ [])
          when is_binary(file) and is_list(args) and is_list(pty_options) do
        case GenServer.start(__MODULE__, {file, args, pty_options}) do
          {:ok, pid} ->
            case GenServer.call(pid, :do_spawn) do
              :ok ->
                {:ok, pid}
              {:error, reason} ->
                {:error, reason}
            end
          error -> error
        end
      end

      @spec write(pid(), binary) :: :ok | {:partial, integer()} | {:error, String.t()}
      def write(pty, data) when is_binary(data) do
        GenServer.call(pty, {:write, data})
      end

      @spec kill(pid, integer) :: :ok
      def kill(_pty, signal) when is_integer(signal) do
        raise "kill/2 is not implemeted on Windows yet"
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

      @impl true
      def init(init_args) do
        {file, args, pty_options} = init_args

        # Initialize arguments
        default_options = default_pty_options()
        options = Keyword.merge(default_options, pty_options)
        file = file || "powershell.exe"
        env = options[:env]
        cwd = Path.expand(options[:cwd])
        cols = options[:cols]
        rows = options[:rows]
        debug = options[:debug] || false
        pipe_name = options[:pipe_name] || "pipe"
        pipe_name = "#{pipe_name}-#{:rand.uniform(100000000)}"
        inherit_cursor = options[:inherit_cursor] || false

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
          debug,
          pipe_name,
          inherit_cursor,
          on_data,
          on_exit
        }

        {:ok, init_pack}
      end

      @impl true
      def handle_call(
            :do_spawn,
            _from,
            state={file, args, env, cwd, cols, rows, debug, pipe_name, inherit_cursor, on_data, on_exit}
          ) do
        case ExPTY.Nif.spawn(file, cols, rows, debug, pipe_name, inherit_cursor) do
          {pty_id, conin, conout} when is_integer(pty_id) ->
            command_line = args_to_command_line(file, args)
            case ExPTY.Nif.priv_connect(pty_id, command_line, cwd, env) do
              {:ok, inner_pid} ->
                {:reply, :ok, %T{
                  pty: pty_id,
                  conin: conin, conout: conout,
                  inner_pid: inner_pid,
                  on_data: on_data,
                  on_exit: on_exit}}
              error ->
                {:reply, error, state}
            end
          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
      end

      @impl true
      def handle_call({:write, data}, _from, %T{pty: pty} = state) do
        {:reply, ExPTY.Nif.write(pty, data), state}
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
      def handle_call({:resize, {cols, rows}}, _from, %T{pty: pty} = state) do
        ret = ExPTY.Nif.resize(pty, cols, rows)
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
      def handle_info({:exit, exit_code}, %T{on_exit: on_exit} = state) do
        case on_exit do
          {:module, module} ->
            module.on_exit(__MODULE__, self(), exit_code, nil)

          {:func, func} ->
            func.(__MODULE__, self(), exit_code, nil)

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

        arg0 =  String.at(arg, 0)
        has_lopsided_enclosing_quote = xor(arg0 != "\"", !String.ends_with?(arg, "\""))
        has_no_eclosing_quotes = arg0 != "\"" && !String.ends_with?(arg, "\"")
        quote? = arg == "" || (:binary.match(arg, " ") != :nomatch || :binary.match(arg, "\t") != :nomatch) && ((String.length(arg) > 0) && (has_lopsided_enclosing_quote || has_no_eclosing_quotes))
        result =
          if quote? do
            "#{result}\""
          else
            result
          end

        bs_count = 0
        {bs_count, result} =
          Enum.reduce(0..String.length(arg)-1, {bs_count, result}, fn index, {bs_count_, result_} ->
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

  platform ->
    defmodule ExPTY.Win do
      @platform platform
      @spec spawn(any, any, any) :: none
      def spawn(_file, _args, _pty_options) do
        raise "Invalid call to platform-specific module `#{inspect(__MODULE__)}` while on #{inspect(@platform)} platform"
      end

      def write(_pty, _data) do
        raise "Invalid call to platform-specific module `#{inspect(__MODULE__)}` while on #{inspect(@platform)} platform"
      end

      def kill(_pty, _signal) do
        raise "Invalid call to platform-specific module `#{inspect(__MODULE__)}` while on #{inspect(@platform)} platform"
      end

      def on_data(_pty, _callback) do
        raise "Invalid call to platform-specific module `#{inspect(__MODULE__)}` while on #{inspect(@platform)} platform"
      end

      def on_exit(_pty, _callback) do
        raise "Invalid call to platform-specific module `#{inspect(__MODULE__)}` while on #{inspect(@platform)} platform"
      end

      def resize(_pty, _cols, _rows) do
        raise "Invalid call to platform-specific module `#{inspect(__MODULE__)}` while on #{inspect(@platform)} platform"
      end
    end
end
