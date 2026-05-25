defmodule ExPTYTest do
  use ExUnit.Case, async: false

  doctest ExPTY

  defmodule ExitCallback do
    def on_exit(module, pty, exit_code, signal_code) do
      send(Process.whereis(:expty_test), {:expty_exit, module, pty, exit_code, signal_code})
    end
  end

  setup do
    Process.register(self(), :expty_test)

    on_exit(fn ->
      if Process.whereis(:expty_test) == self() do
        Process.unregister(:expty_test)
      end
    end)

    :ok
  end

  test "returns an error when a Unix executable cannot be spawned" do
    if unix?() do
      assert {:error, reason} = ExPTY.spawn("/definitely-not-expty", [])
      assert is_binary(reason)
    end
  end

  test "keeps module on_exit callback passed during spawn" do
    if unix?() do
      executable = System.find_executable("true") || "/usr/bin/true"

      assert {:ok, pty} = ExPTY.spawn(executable, [], on_exit: ExitCallback)
      assert_receive {:expty_exit, ExPTY, ^pty, 0, 0}, 1_000
    end
  end

  defp unix? do
    match?({:unix, _}, :os.type())
  end
end
