defmodule ExPTY.UnixTest do
  use ExUnit.Case, async: false

  @concurrent_process_count 512
  @fd_probe """
  open_fds=
  tty_fds=
  for path in /dev/fd/*; do
    fd=${path##*/}
    case "$fd" in
      0|1|2) ;;
      *)
        if [ -e "$path" ]; then
          open_fds="$open_fds $fd"
        fi
        if [ -t "$fd" ]; then
          tty_fds="$tty_fds $fd"
        fi
        ;;
    esac
  done
  printf 'open-fds:%s;tty-fds:%s\n' "$open_fds" "$tty_fds"
  """
  @moduletag skip: not match?({:unix, _}, :os.type())
  @moduletag timeout: 60_000

  test "spawns short-lived processes concurrently" do
    executable = System.find_executable("true") || "/usr/bin/true"
    owner = self()
    ref = make_ref()

    results =
      1..@concurrent_process_count
      |> Task.async_stream(
        fn _ ->
          ExPTY.spawn(executable, [],
            cwd: "/",
            on_exit: fn _, pty, exit_code, signal_code ->
              send(owner, {ref, pty, exit_code, signal_code})
            end
          )
        end,
        max_concurrency: 64,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.to_list()

    ptys = for {:ok, {:ok, pty}} when is_pid(pty) <- results, do: pty

    on_exit(fn -> Enum.each(ptys, &stop_pty/1) end)

    failures =
      Enum.reject(results, fn
        {:ok, {:ok, pty}} when is_pid(pty) -> true
        _ -> false
      end)

    assert failures == []
    assert length(ptys) == @concurrent_process_count

    await_exits(ref, MapSet.new(ptys), System.monotonic_time(:millisecond) + 10_000)
    Enum.each(ptys, &stop_pty/1)
  end

  test "closes inherited file descriptors by default" do
    assert %{open: [], tty: []} = probe_fds()
  end

  test "does not leak PTY descriptors when descriptor inheritance is enabled" do
    assert %{open: open_fds, tty: []} = probe_fds(close_fds: false)
    refute "3" in open_fds
  end

  defp await_exits(ref, pending, deadline) do
    if MapSet.size(pending) == 0 do
      :ok
    else
      timeout = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {^ref, pty, 0, 0} ->
          if MapSet.member?(pending, pty) do
            await_exits(ref, MapSet.delete(pending, pty), deadline)
          else
            flunk("received an unexpected exit notification from #{inspect(pty)}")
          end

        {^ref, pty, exit_code, signal_code} ->
          flunk("process #{inspect(pty)} exited with code #{exit_code} and signal #{signal_code}")
      after
        timeout ->
          flunk("timed out waiting for #{MapSet.size(pending)} processes to exit")
      end
    end
  end

  defp probe_fds(options \\ []) do
    owner = self()
    ref = make_ref()
    shell = System.find_executable("sh") || "/bin/sh"

    options =
      Keyword.merge(options,
        cwd: "/",
        on_data: fn _, _, data -> send(owner, {ref, :data, data}) end,
        on_exit: fn _, _, exit_code, signal_code ->
          send(owner, {ref, :exit, exit_code, signal_code})
        end
      )

    assert {:ok, pty} = ExPTY.spawn(shell, ["-c", @fd_probe], options)
    on_exit(fn -> stop_pty(pty) end)

    output =
      await_probe(ref, "open-fds:", "", nil, System.monotonic_time(:millisecond) + 5_000)

    stop_pty(pty)

    assert [open_fds, tty_fds] =
             Regex.run(~r/open-fds:([^;\r\n]*);tty-fds:([^\r\n]*)/, output,
               capture: :all_but_first
             )

    %{open: split_fds(open_fds), tty: split_fds(tty_fds)}
  end

  defp split_fds(fds), do: String.split(fds, " ", trim: true)

  defp await_probe(ref, marker, output, exit_status, deadline) do
    if exit_status == {0, 0} and String.contains?(output, marker) do
      output
    else
      timeout = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {^ref, :data, data} ->
          await_probe(ref, marker, output <> data, exit_status, deadline)

        {^ref, :exit, 0, 0} ->
          await_probe(ref, marker, output, {0, 0}, deadline)

        {^ref, :exit, exit_code, signal_code} ->
          flunk("fd probe exited with code #{exit_code} and signal #{signal_code}")
      after
        timeout ->
          flunk("timed out waiting for fd probe output")
      end
    end
  end

  defp stop_pty(pty) do
    if Process.alive?(pty), do: GenServer.stop(pty)
  end
end
