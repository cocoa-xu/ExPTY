**(Warning: this project is still WIP, there are a lot of things (like proper cleanups) not done yet, and right now it shows a minimal working product (without proper cleanups yet!) with Kino. Use at your own risk.**

**Any help/PR is welcome!**

# ExPTY

`ExPTY` firstly fills the gap that executables spawned by `Port` do not have a tty available to them.

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
/dev/ttys032
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

Most importantly, and as a consequence of the first point, we can now forward all data to somewhere else (e.g., via WebSocket to LiveBook) have a full terminal experience.

## Installation

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

