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

  test "kill signals the spawned process group" do
    if unix?() do
      test_pid = self()

      {:ok, pty} =
        ExPTY.spawn("/bin/sh", ["-c", "trap '' HUP; sleep 60 & echo child:$!; wait"],
          on_data: fn _, _, data -> send(test_pid, {:pty_data, data}) end
        )

      child_pid = receive_child_pid()
      on_exit(fn -> kill_pid(child_pid) end)

      assert process_alive?(child_pid)
      assert ExPTY.kill(pty, 15) == :ok
      refute_process_alive(child_pid)
    end
  end

  test "keeps module on_exit callback passed during spawn" do
    {executable, args, signal_code} =
      if unix?() do
        {System.find_executable("true") || "/usr/bin/true", [], 0}
      else
        {System.find_executable("cmd") || "cmd.exe", ["/c", "exit", "0"], nil}
      end

    assert {:ok, pty} = ExPTY.spawn(executable, args, on_exit: ExitCallback)
    assert_receive {:expty_exit, ExPTY, ^pty, 0, ^signal_code}, 5_000
  end

  defp unix? do
    match?({:unix, _}, :os.type())
  end

  defp receive_child_pid(buffer \\ "") do
    receive do
      {:pty_data, data} ->
        buffer = buffer <> data

        case Regex.run(~r/child:(\d+)/, buffer) do
          [_, pid] -> String.to_integer(pid)
          nil -> receive_child_pid(buffer)
        end
    after
      2_000 -> flunk("timed out waiting for child pid")
    end
  end

  defp refute_process_alive(pid, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    if process_alive?(pid) do
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("expected OS process #{pid} to exit")
      else
        Process.sleep(25)
        refute_process_alive(pid, deadline)
      end
    end
  end

  defp process_alive?(pid) do
    if zombie_process?(pid) do
      false
    else
      case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
        {_, 0} -> true
        _ -> false
      end
    end
  end

  defp zombie_process?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, status} -> Regex.match?(~r/^\d+ \(.*\) Z /, status)
      _ -> false
    end
  end

  defp kill_pid(pid) do
    System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end
end
