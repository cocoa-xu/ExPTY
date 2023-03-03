case :os.type() do
  {:win32, _} ->
    defmodule ExPTY.Win do
      use GenServer

      defstruct [:pty, :conin, :conout]
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

      def start_process(file, args, pty_options \\ [])
          when is_binary(file) and is_list(args) and is_list(pty_options) do
        case GenServer.start(__MODULE__, {file, args, pty_options}) do
          {pty_id, conin, conout} when is_integer(pty_id) ->
            # conout_connection = ExPTY.Win.ConoutConnection.new(conout)
            {pty_id, conin, conout}

          {:error, reason} ->
            {:error, reason}
        end
      end

      @impl true
      def init(init_args) do
        {file, args, pty_options} = init_args

        # Initialize arguments
        default_options = default_pty_options()
        options = Keyword.merge(default_options, pty_options)
        file = options[:file] || "powershell.exe"
        env = options[:env]
        cwd = Path.expand(options[:cwd])
        cols = options[:cols]
        rows = options[:rows]
        debug = options[:debug] || false
        pipe_name = options[:pipe_name] || "pipe"
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
            {file, args, env, cwd, cols, rows, debug, pipe_name, inherit_cursor, on_data, on_exit}
          ) do
        # Generated incremental number that has no real purpose besides  using it
        # as a terminal id.
        case ExPTY.Nif.start_process(file, cols, rows, debug, pipe_name, inherit_cursor) do
          {pty_id, conin, conout} when is_integer(pty_id) ->
            {:reply, {self(), {pty_id, conin, conout}},
             %T{pty: pty_id, conin: conin, conout: conout}}

          # conout_connection = ExPTY.Win.ConoutConnection.new(conout)
          {:error, reason} ->
            {:error, reason}
        end
      end
    end

  _ ->
    nil
end
