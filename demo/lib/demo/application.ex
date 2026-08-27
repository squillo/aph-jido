defmodule Demo.Application do
  @moduledoc """
  Supervises the demo's single piece of infrastructure: the `Demo.Jido`
  instance (PRD-001 §7.4 — "Demo.Jido supervised"). Agents are NOT
  supervised here; they start on demand under the instance's own
  DynamicSupervisor via `Demo.Jido.start_agent/2`.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [Demo.Jido]

    Supervisor.start_link(children, strategy: :one_for_one, name: Demo.Supervisor)
  end
end
