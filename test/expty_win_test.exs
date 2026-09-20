defmodule ExPTY.WinTest do
  use ExUnit.Case, async: false

  @moduletag skip: not match?({:win32, _}, :os.type())
  @moduletag timeout: 120_000

  @shell "cmd.exe"

  test "stopping the owner closes the pseudoconsole and the spawned process" do
    assert {:ok, pty} = ExPTY.spawn(@shell, [])
    inner_pid = :sys.get_state(pty).inner_pid
    assert os_process_alive?(inner_pid)

    assert GenServer.stop(pty) == :ok
    refute_os_process_alive(inner_pid)
  end

  test "spawning and stopping repeatedly leaves nothing behind" do
    owner = self()

    for _ <- 1..10 do
      ref = make_ref()

      assert {:ok, pty} =
               ExPTY.spawn(@shell, ["/c", "exit", "0"],
                 on_exit: fn _, _, exit_code, signal_code ->
                   send(owner, {ref, exit_code, signal_code})
                 end
               )

      assert_receive {^ref, 0, nil}, 10_000
      assert GenServer.stop(pty) == :ok
    end
  end

  test "writing and resizing after the process exited does not take the owner down" do
    owner = self()
    ref = make_ref()

    assert {:ok, pty} =
             ExPTY.spawn(@shell, ["/c", "exit", "0"],
               on_exit: fn _, _, exit_code, _ -> send(owner, {ref, exit_code}) end
             )

    assert_receive {^ref, 0}, 10_000

    assert ExPTY.write(pty, "echo hello\r") == {:partial, 0}
    assert {:error, _reason} = ExPTY.resize(pty, 100, 40)
    assert Process.alive?(pty)

    assert GenServer.stop(pty) == :ok
  end

  test "set_echo reports itself unavailable instead of taking the owner down" do
    assert {:ok, pty} = ExPTY.spawn(@shell, [])

    assert {:error, _reason} = ExPTY.set_echo(pty, true)
    assert Process.alive?(pty)

    assert GenServer.stop(pty) == :ok
  end

  defp os_process_alive?(pid) do
    {out, _} =
      System.cmd("tasklist", ["/FI", "PID eq #{pid}", "/NH", "/FO", "CSV"],
        stderr_to_stdout: true
      )

    String.contains?(out, "\"#{pid}\"")
  end

  defp refute_os_process_alive(pid, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 10_000

    if os_process_alive?(pid) do
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("expected OS process #{pid} to exit")
      else
        Process.sleep(50)
        refute_os_process_alive(pid, deadline)
      end
    end
  end
end
