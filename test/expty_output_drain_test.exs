defmodule ExPTY.OutputDrainTest do
  @moduledoc """
  Protects final-output ordering for opted-in drained exit callbacks.

  The existing ExPTY server owns callback delivery. These tests cover both
  arrival orders without timers; native Unix tests cover the reader signal.
  """
  use ExUnit.Case, async: true

  test "drained exit waits for the reader after process exit" do
    state = callback_state(drain_on_exit: true)

    assert {:noreply, state} = ExPTY.handle_info({:exit, 0, 0}, state)
    refute_receive {:exit, _, _}, 0

    assert {:noreply, state} = ExPTY.handle_info({:data, "final output"}, state)
    assert_receive {:data, "final output"}, 0
    refute_receive {:exit, _, _}, 0

    assert {:noreply, _state} = ExPTY.handle_info(:output_closed, state)
    assert_receive {:exit, 0, 0}, 0
  end

  test "drained exit waits for process status after the reader closes" do
    state = callback_state(drain_on_exit: true)

    assert {:noreply, state} = ExPTY.handle_info({:data, "output"}, state)
    assert_receive {:data, "output"}, 0
    assert {:noreply, state} = ExPTY.handle_info(:output_closed, state)
    refute_receive {:exit, _, _}, 0

    assert {:noreply, _state} = ExPTY.handle_info({:exit, 23, 0}, state)
    assert_receive {:exit, 23, 0}, 0
  end

  test "drained exit is delivered only once" do
    state = callback_state(drain_on_exit: true)
    assert {:noreply, state} = ExPTY.handle_info({:exit, 0, 15}, state)
    assert {:noreply, state} = ExPTY.handle_info(:output_closed, state)
    assert_receive {:exit, 0, 15}, 0

    assert {:noreply, state} = ExPTY.handle_info(:output_closed, state)
    assert {:noreply, _state} = ExPTY.handle_info({:exit, 0, 15}, state)
    refute_receive {:exit, _, _}, 0
  end

  test "default exit does not wait for reader closure" do
    state = callback_state(drain_on_exit: false)
    assert {:noreply, state} = ExPTY.handle_info({:exit, 0, 0}, state)
    assert_receive {:exit, 0, 0}, 0

    assert {:noreply, _state} = ExPTY.handle_info(:output_closed, state)
    refute_receive {:exit, _, _}, 0
  end

  test "drain_on_exit requires a boolean" do
    assert_raise ArgumentError, "drain_on_exit must be a boolean", fn ->
      ExPTY.init({"sh", [], drain_on_exit: :yes})
    end
  end

  defp callback_state(options) do
    owner = self()

    Map.merge(%ExPTY{}, %{
      drain_on_exit: Keyword.fetch!(options, :drain_on_exit),
      output_closed: false,
      exit_status: nil,
      on_data: {:func, fn _, _, data -> send(owner, {:data, data}) end},
      on_exit: {:func, fn _, _, code, signal -> send(owner, {:exit, code, signal}) end}
    })
  end
end
