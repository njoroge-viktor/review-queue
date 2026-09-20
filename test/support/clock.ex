defmodule ReviewQueue.TestClock do
  @moduledoc """
  A manually advanced clock.

  Lease-expiry tests that `Process.sleep/1` are slow and flaky. Injecting time
  makes them instant and deterministic.
  """

  use Agent

  @spec start_link(DateTime.t()) :: Agent.on_start()
  def start_link(start \\ ~U[2026-01-01 00:00:00Z]) do
    Agent.start_link(fn -> start end)
  end

  @spec now(pid()) :: DateTime.t()
  def now(pid), do: Agent.get(pid, & &1)

  @spec advance(pid(), integer()) :: :ok
  def advance(pid, milliseconds) do
    Agent.update(pid, &DateTime.add(&1, milliseconds, :millisecond))
  end

  @doc "A zero-arity function suitable for the queue's `:clock` option."
  @spec fun(pid()) :: (-> DateTime.t())
  def fun(pid), do: fn -> now(pid) end
end
