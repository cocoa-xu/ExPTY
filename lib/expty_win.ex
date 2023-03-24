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
            case ExPTY.Nif.priv_connect(pty_id, file, args, cwd, env) do
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
    end

  _ ->
    nil
end
