**(Warning: this project is still WIP, there are a lot of things (like proper cleanups) not done yet, and right now it shows a minimal working product (without proper cleanups yet!) with Kino. Use at your own risk.**

**Any help/PR is welcome!**

# ExPTY

`ExPTY` fills the gap where executables spawned by `Port` do not have a tty available to them.

<table>
<tr>
<td> Module </td> <td> Example </td>
</tr>
<tr>
<td> <code>ExPTY</code> </td>
<td>

```elixir
iex> pty = ExPTY.spawn("tty", [], on_data: fn _, _, data -> IO.write(data) end)
#PID<0.229.0>
/dev/ttys001
```

</td>
</tr>
<tr>
<td> <code>Port</code> </td>
<td>

```elixir
iex> Port.open({:spawn, "tty"}, [:binary])
#Port<0.5>
iex> flush()
{#Port<0.5>, {:data, "not a tty\n"}}
:ok
```

</td>
</tr>
</table>

Most importantly, and as a consequence of the point above, we can now forward all data to somewhere else (e.g., via WebSocket to LiveBook) have a full terminal experience.

## Example

```elixir
defmodule Example do  
  def run do
    {:ok, pty} =
      ExPTY.spawn("tty", [],
        name: "xterm-color",
        cols: 80,
        rows: 24,
        on_data: __MODULE__,
        on_exit: __MODULE__
      )

    pty
  end

  def on_data(ExPTY, _erl_pid, data) do
    IO.write(data)
  end

  def on_exit(ExPTY, _erl_pid, exit_code, signal_code) do
    IO.puts("exit_code=#{exit_code}, signal_code=#{signal_code}")
  end
end
```

## Installation

### Unix
For Unix systems it's pretty much what you would expect, a working C/C++ toolchain, CMake, Make.

### Windows
For Windows users, if you're not using Livebook, it's also the same as installing any other NIF libraries. 
  
**However, if you're trying to install it on a Livebook, you need to set up some environment variables.**

Normally, these environment variables would be by `vcvarsall.bat` in your cmd (or powershell, or any other shell), but here we have to do it manually:

- Open the `x64 Native Tools Command Prompt` (on 64-bit system) or `x86 Native Tools Command Prompt` (on 32-bit system)
- In the command prompt window, type `set`, and you will see all the environment variables
- Copy the output printed by `set` command, and store them in a variable (say `env`) in the setup cell in your livebook
- export these environment variables before `Mix.install` using the following code

```elixir
Enum.each(String.split(env, "\n"), fn env_var ->
  case String.split(env_var, "=", parts: 2) do
    [name, value] ->
      System.put_env(name, value)
    _ -> :ok
  end
end)
```

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `ExPTY` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:expty, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/expty>.

## Acknowledgements

This project is largely based on [microsoft/node-pty](https://github.com/microsoft/node-pty). Many thanks to all developers and maintainers, without them this wouldn't be possible.
