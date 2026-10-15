defmodule ExPTY.ExitOrderTest do
  use ExUnit.Case, async: false

  @moduletag skip: not match?({:unix, _}, :os.type())
  @moduletag timeout: 120_000

  @iterations 300

  test "on_exit follows all output written before the process exited" do
    shell = System.find_executable("sh") || "/bin/sh"

    lost =
      1..@iterations
      |> Task.async_stream(
        fn index ->
          owner = self()
          ref = make_ref()
          marker = "exit-order-#{index}"

          {:ok, pty} =
            ExPTY.spawn(shell, ["-c", "printf #{marker}; exit 3"],
              cwd: "/",
              on_data: fn _, _, data -> send(owner, {ref, :data, data}) end,
              on_exit: fn _, _, code, _signal -> send(owner, {ref, :exit, code}) end
            )

          output = collect_until_exit(ref, "", 3)
          GenServer.stop(pty, :normal)
          if output == marker, do: :ok, else: {:lost, marker, output}
        end,
        max_concurrency: System.schedulers_online() * 4,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.reject(&match?({:ok, :ok}, &1))

    assert lost == []
  end

  test "a descendant holding the terminal open delays on_exit only until the drain timeout" do
    shell = System.find_executable("sh") || "/bin/sh"
    owner = self()
    ref = make_ref()

    {:ok, pty} =
      ExPTY.spawn(shell, ["-c", "printf held; (trap '' HUP; exec sleep 30) & exit 4"],
        cwd: "/",
        exit_drain_timeout: 100,
        on_data: fn _, _, data -> send(owner, {ref, :data, data}) end,
        on_exit: fn _, _, code, _signal -> send(owner, {ref, :exit, code}) end
      )

    on_exit(fn -> stop(pty) end)
    started = System.monotonic_time(:millisecond)
    # Linux hangs up the terminal when the session leader exits, so the reader
    # can close before the timeout there. Other Unix systems keep it open and
    # rely on the timeout. Either way, on_exit must not wait for the descendant.
    assert collect_until_exit(ref, "", 4) == "held"
    assert System.monotonic_time(:millisecond) - started < 10_000
  end

  describe "exit and reader events in either order" do
    setup do
      owner = self()
      ref = make_ref()
      shell = System.find_executable("sh") || "/bin/sh"

      # A long-lived process keeps the real native events out of the way while
      # the test delivers both orders of the native messages itself.
      {:ok, pty} =
        ExPTY.spawn(shell, ["-c", "sleep 30"],
          cwd: "/",
          exit_drain_timeout: 60_000,
          on_data: fn _, _, data -> send(owner, {ref, :data, data}) end,
          on_exit: fn _, _, code, signal -> send(owner, {ref, :exit, code, signal}) end
        )

      on_exit(fn -> stop(pty) end)
      {:ok, pty: pty, ref: ref}
    end

    test "an exit status that overtakes output waits for the reader to close", %{
      pty: pty,
      ref: ref
    } do
      send(pty, {:exit, 7, 0})
      send(pty, {:data, "late"})
      :sys.get_state(pty)

      assert_received {^ref, :data, "late"}
      refute_received {^ref, :exit, 7, 0}

      send(pty, :closed)
      :sys.get_state(pty)
      assert_received {^ref, :exit, 7, 0}
    end

    test "an exit status after the reader closed is delivered at once", %{pty: pty, ref: ref} do
      send(pty, {:data, "early"})
      send(pty, :closed)
      send(pty, {:exit, 8, 0})
      :sys.get_state(pty)

      assert_received {^ref, :data, "early"}
      assert_received {^ref, :exit, 8, 0}
    end
  end

  test "the drain timeout delivers a held exit status once" do
    owner = self()
    ref = make_ref()
    shell = System.find_executable("sh") || "/bin/sh"

    {:ok, pty} =
      ExPTY.spawn(shell, ["-c", "sleep 30"],
        cwd: "/",
        exit_drain_timeout: 0,
        on_exit: fn _, _, code, signal -> send(owner, {ref, :exit, code, signal}) end
      )

    on_exit(fn -> stop(pty) end)
    send(pty, {:exit, 9, 0})
    assert_receive {^ref, :exit, 9, 0}, 1_000
    send(pty, :closed)
    :sys.get_state(pty)
    refute_received {^ref, :exit, 9, 0}
  end

  defp collect_until_exit(ref, acc, code) do
    receive do
      {^ref, :data, data} -> collect_until_exit(ref, acc <> data, code)
      {^ref, :exit, ^code} -> acc
    after
      10_000 -> flunk("no exit notification")
    end
  end

  defp stop(pty) do
    if Process.alive?(pty) do
      ExPTY.kill(pty, 9)
      GenServer.stop(pty, :normal)
    end
  catch
    :exit, _ -> :ok
  end
end
