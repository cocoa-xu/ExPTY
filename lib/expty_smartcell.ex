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
      {:ok, pty} = ExPTY.spawn("bash", [])
      ctx = assign(ctx, [pty: pty])
      on_data = fn _,_,data ->
        broadcast_event(ctx, "data", %{data: data})
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
      ExPTY.write(ctx.assigns.pty, data)
      {:noreply, ctx}
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
