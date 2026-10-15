defmodule ExPTY.OutputDrainUnixTest do
  @moduledoc """
  Protects final output delivery from real Unix PTYs.

  The native reader supplies closure and the ExPTY server owns callback order.
  These tests cover empty output, multiple native reads, cancellation, and
  inherited terminals; callback-order unit tests cover both event interleavings.
  """
  use ExUnit.Case, async: false

  @moduletag skip: not match?({:unix, _}, :os.type())
  @command_timeout 5_000
  @terminal_holder """
  trap '' HUP
  (
    exec 3<"$1"
    printf ready
    cat <&3
  ) &
  IFS= read -r command
  printf final
  exit 23
  """

  test "drained exit follows all output, including empty and multi-chunk output" do
    for expected <- ["", "final output", String.duplicate("x", 16_384)] do
      {_pty, ref} = spawn_drained(["-c", "printf %s \"$1\"", "output-test", expected])
      assert {^expected, 0, 0} = receive_exit(ref)
    end
  end

  test "cancellation closes the reader and delivers the process signal" do
    {pty, ref} = spawn_drained(["-c", "printf ready; exec sleep 60"])
    assert_output(ref, "ready")

    assert :ok = ExPTY.kill(pty, 15)
    assert {"", 0, 15} = receive_exit(ref)
  end

  @tag :tmp_dir
  @tag skip: not match?({:unix, :linux}, :os.type())
  test "waits for an inherited terminal to close after the spawned process exits", %{
    tmp_dir: tmp_dir
  } do
    fifo = Path.join(tmp_dir, "release")
    assert {_, 0} = System.cmd("mkfifo", [fifo], stderr_to_stdout: true)
    assert {:ok, release} = File.open(fifo, [:read, :write])

    on_exit(fn ->
      File.close(release)
      File.rm(fifo)
    end)

    {pty, ref} = spawn_drained(["-c", @terminal_holder, "terminal-holder", fifo])
    assert_output(ref, "ready")

    :erlang.trace(pty, true, [:receive])
    assert :ok = ExPTY.write(pty, "exit\n")
    assert_receive {:trace, ^pty, :receive, {:exit, 23, 0}}, @command_timeout
    :erlang.trace(pty, false, [:receive])

    state = :sys.get_state(pty)
    assert state.exit_status == {23, 0}
    refute state.output_closed
    refute_received {^ref, :exit, _, _}

    assert :ok = File.close(release)
    assert {"final", 23, 0} = receive_exit(ref)
  end

  defp spawn_drained(args) do
    owner = self()
    ref = make_ref()

    assert {:ok, pty} =
             ExPTY.spawn("/bin/sh", args,
               drain_on_exit: true,
               on_data: fn _, _, data -> send(owner, {ref, :data, data}) end,
               on_exit: fn _, _, code, signal -> send(owner, {ref, :exit, code, signal}) end
             )

    on_exit(fn ->
      unless :sys.get_state(pty).exit_status == :delivered, do: ExPTY.kill(pty, 9)
      GenServer.stop(pty)
    end)

    {pty, ref}
  end

  defp assert_output(ref, expected, received \\ "")
  defp assert_output(_ref, expected, expected), do: :ok

  defp assert_output(ref, expected, received) do
    assert_receive {^ref, :data, data}, @command_timeout
    received = received <> data
    assert String.starts_with?(expected, received)
    assert_output(ref, expected, received)
  end

  defp receive_exit(ref) do
    receive_exit(ref, [], System.monotonic_time(:millisecond) + @command_timeout)
  end

  defp receive_exit(ref, chunks, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^ref, :data, data} -> receive_exit(ref, [data | chunks], deadline)
      {^ref, :exit, code, signal} -> {IO.iodata_to_binary(Enum.reverse(chunks)), code, signal}
    after
      timeout -> flunk("timed out waiting for drained process exit")
    end
  end
end
