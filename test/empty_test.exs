defmodule ExPTYTest do
  use ExUnit.Case
  doctest ExPTY

  test "greets the world" do
    assert ExPTY.hello() == :world
  end
end
