if !Code.ensure_loaded?(Kino.SmartCell) do
  defmodule ExPTY.SmartCell do
  end
else
  defmodule ExPTY.SmartCell do
    use Kino.JS, assets_path: "lib/assets"
    use Kino.JS.Live
    use Kino.SmartCell, name: "ExPTY"

    require Logger

    @impl true
    def init(attrs, ctx) do
      executable = attrs["executable"] || default_executable()

      ctx =
        assign(ctx,
          executable: executable,
          pty: nil,
          started?: false
        )

      {:ok, ctx}
    end

    @impl true
    def handle_connect(ctx) do
      fields = %{
        executable: ctx.assigns.executable,
        started: ctx.assigns.started?
      }

      {:ok, fields, ctx}
    end

    @impl true
    def handle_event("start_executable", data, ctx) do
      if ctx.assigns.started? do
        Logger.warning("Executable already started")
        {:noreply, ctx}
      else
        executable =
          case data do
            %{"executable" => executable} ->
              executable

            _ ->
              default_executable()
          end

        Logger.info("Starting executable: #{executable}")
        {:ok, pty} = ExPTY.spawn(executable, [])

        ExPTY.on_data(pty, fn _, _, data ->
          broadcast_event(ctx, "data", %{data: Base.encode64(data)})
        end)

        {:noreply,
         assign(ctx,
           pty: pty,
           started?: true
         )}
      end
    end

    def handle_event("stop_executable", _, ctx) do
      stop_executable(ctx)

      {:noreply, assign(ctx, pty: nil, started?: false)}
    end

    def handle_event("on_key", %{"data" => data}, ctx) do
      if is_pid(ctx.assigns.pty) do
        case Base.decode64(data) do
          {:ok, data} ->
            ExPTY.write(ctx.assigns.pty, data)

          _ ->
            nil
        end
      end

      {:noreply, ctx}
    end

    def handle_event("resize", %{"cols" => cols, "rows" => rows}, ctx)
        when is_integer(cols) and cols > 0 and is_integer(rows) and rows > 0 do
      if is_pid(ctx.assigns.pty) do
        ExPTY.resize(ctx.assigns.pty, cols, rows)
      else
        Process.send_after(self(), {:resize, cols, rows}, 500)
      end

      {:noreply, ctx}
    end

    def handle_event(_unknown_event, _data, ctx) do
      {:noreply, ctx}
    end

    @impl true
    def handle_info({:resize, cols, rows}, ctx) do
      if is_pid(ctx.assigns.pty) do
        ExPTY.resize(ctx.assigns.pty, cols, rows)
      end

      {:noreply, ctx}
    end

    @impl true
    def terminate(_, ctx) do
      stop_executable(ctx)

      :ok
    end

    @impl true
    def to_attrs(ctx) do
      %{
        "executable" => ctx.assigns.executable
      }
    end

    @impl true
    def to_source(_attrs) do
      ""
    end

    defp default_executable do
      case :os.type() do
        {:unix, :darwin} ->
          "zsh"

        {:unix, _} ->
          "bash"

        {:win32, _} ->
          "powershell.exe"
      end
    end

    defp stop_executable(ctx) do
      if is_pid(ctx.assigns.pty) do
        # signal 9: SIGKILL
        case :os.type() do
          {:unix, _} ->
            ExPTY.kill(ctx.assigns.pty, 9)

          {:win32, _} ->
            # TODO: implement ExPTY.Win.kill/2
            nil
        end
      end
    end
  end
end
