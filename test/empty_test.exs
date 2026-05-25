defmodule ExPTYTest do
  use ExUnit.Case
  doctest ExPTY

  if match?({:unix, _}, :os.type()) do
    test "kill signals the spawned process group" do
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
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp kill_pid(pid) do
    System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end
end
