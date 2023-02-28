defmodule ExPTY.Options do
  defstruct [
    name: "xterm-color",
    cols: 80,
    rows: 24,
    env: System.get_env(),
    cwd: Path.expand("~"),
    encoding: "utf-8",
    handleFlowControl: false,
    flowControlPause: "\x13",
    flowControlResume:  "\x11",
  ]

  alias __MODULE__, as: T

  @spec default :: %T{}
  def default do
    %T{}
  end
end
