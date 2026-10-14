defmodule ExPTY.OutputDrainUnixTest do
  @moduledoc """
  Protects final output delivery from real Unix PTYs.

  The native reader supplies closure and the ExPTY server owns callback order.
  These tests cover empty output, multiple native reads, and cancellation;
  callback-order unit tests cover both event interleavings.
  """
  use ExUnit.Case, async: false

  @moduletag skip: not match?({:unix, _}, :os.type())
  @command_timeout 5_000

  test "drained exit follows all output, including empty and multi-chunk output" do
    for expected <- ["", "final output", String.duplicate("x", 16_384)] do
      {_pty, ref} = spawn_drained(["-c", "printf %s \"$1\"", "output-test", expected])
      assert {^expected, 0, 0} = receive_exit(ref)
    end
  end

  test "cancellation closes the reader and delivers the process signal" do
    {pty, ref} = spawn_drained(["-c", "printf ready; exec sleep 60"])
    assert_receive {^ref, :data, "ready"}, @command_timeout

    assert :ok = ExPTY.kill(pty, 15)
    assert {"", 0, 15} = receive_exit(ref)
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
