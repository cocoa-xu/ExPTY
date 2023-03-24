if !Code.ensure_loaded?(Kino.SmartCell) do
  defmodule ExPTY.SmartCell do
  end
else
  case :os.type() do
    {:win32, _} ->
      defmodule ExPTY.SmartCell do
        use Kino.JS, assets_path: "lib/assets"
        use Kino.JS.Live
        use Kino.SmartCell, name: "ExPTY"

        alias ExPTY.Win, as: ExPTY

        @impl true
        def init(_attrs, ctx) do
          {:ok, pty} = ExPTY.spawn("powershell.exe", [])
          ctx = assign(ctx, pty: pty)

          on_data = fn _, _, data ->
            broadcast_event(ctx, "data", %{data: Base.encode64(data)})
          end

          ExPTY.on_data(pty, on_data)
          {:ok, ctx}
        end

        @impl true
        def handle_connect(ctx) do
          {:ok, %{}, ctx}
        end

        @impl true
        def handle_event("on_key", %{"data" => data}, ctx) do
          case Base.decode64(data) do
            {:ok, data} ->
              ExPTY.write(ctx.assigns.pty, data)

            _ ->
              nil
          end

          {:noreply, ctx}
        end

        @impl true
        def handle_event("resize", %{"cols" => cols, "rows" => rows}, ctx)
            when is_integer(cols) and cols > 0 and is_integer(rows) and rows > 0 do
          ExPTY.resize(ctx.assigns.pty, cols, rows)
          {:noreply, ctx}
        end

        @impl true
        def handle_event(unknown_event, data, ctx) do
          IO.puts("[debug] unknown event: #{inspect(unknown_event)}, data: #{inspect(data)}")
          {:noreply, ctx}
        end

        @impl true
        def terminate(_, ctx) do
          # signal 9: SIGKILL
          IO.puts("[debug] ExPTY.SmartCell.terminate/2")
          # ExPTY.kill(ctx.assigns.pty, 9)
          :ok
        end

        @impl true
        def to_attrs(_) do
          %{}
        end

        @impl true
        def to_source(_attrs) do
          ""
        end
      end

    _ ->
      defmodule ExPTY.SmartCell do
        use Kino.JS, assets_path: "lib/assets"
        use Kino.JS.Live
        use Kino.SmartCell, name: "ExPTY"

        alias ExPTY.Unix, as: ExPTY

        @impl true
        def init(_attrs, ctx) do
          {:ok, pty} = ExPTY.spawn("bash", [])
          ctx = assign(ctx, pty: pty)

          on_data = fn _, _, data ->
            broadcast_event(ctx, "data", %{data: Base.encode64(data)})
          end

          ExPTY.on_data(pty, on_data)
          {:ok, ctx}
        end

        @impl true
        def handle_connect(ctx) do
          {:ok, %{}, ctx}
        end

        @impl true
        def handle_event("on_key", %{"data" => data}, ctx) do
          case Base.decode64(data) do
            {:ok, data} ->
              ExPTY.write(ctx.assigns.pty, data)

            _ ->
              nil
          end

          {:noreply, ctx}
        end

        @impl true
        def handle_event("resize", %{"cols" => cols, "rows" => rows}, ctx)
            when is_integer(cols) and cols > 0 and is_integer(rows) and rows > 0 do
          ExPTY.resize(ctx.assigns.pty, cols, rows)
          {:noreply, ctx}
        end

        @impl true
        def handle_event(unknown_event, data, ctx) do
          IO.puts("[debug] unknown event: #{inspect(unknown_event)}, data: #{inspect(data)}")
          {:noreply, ctx}
        end

        @impl true
        def terminate(_, ctx) do
          # signal 9: SIGKILL
          IO.puts("[debug] ExPTY.SmartCell.terminate/2")
          ExPTY.kill(ctx.assigns.pty, 9)
          :ok
        end

        @impl true
        def to_attrs(_) do
          %{}
        end

        @impl true
        def to_source(_attrs) do
          ""
        end
      end
  end
end
