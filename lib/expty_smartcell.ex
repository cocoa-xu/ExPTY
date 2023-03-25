if !Code.ensure_loaded?(Kino.SmartCell) do
  defmodule ExPTY.SmartCell do
  end
else
  defmodule ExPTY.SmartCell do
    use Kino.JS, assets_path: "lib/assets"
    use Kino.JS.Live
    use Kino.SmartCell, name: "ExPTY"

    @impl true
    def init(_attrs, ctx) do
      shell =
        case :os.type() do
          {:unix, _} ->
            "bash"
          {:win32, _} ->
            "powershell.exe"
        end
      {:ok, pty} = ExPTY.spawn(shell, [])
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
    def handle_event(_unknown_event, _data, ctx) do
      {:noreply, ctx}
    end

    @impl true
    def terminate(_, ctx) do
      # signal 9: SIGKILL
      case :os.type() do
        {:unix, _} ->
          ExPTY.kill(ctx.assigns.pty, 9)
        {:win32, _} ->
          # TODO: implement ExPTY.Win.kill/2
          nil
      end

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
