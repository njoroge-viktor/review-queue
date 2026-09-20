defmodule ReviewQueue.Application do
  @moduledoc """
  OTP application and supervision tree.

  The queue is supervised with `:permanent` restart. If it crashes, the
  supervisor restarts it and in-flight leases are lost — which is correct:
  a lost lease returns its task to the pool, and re-reviewing a task is
  cheap where losing one is not.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {ReviewQueue.Queue, queue_opts()},
      http_server()
    ]

    # :one_for_one — the HTTP layer and the queue fail independently. A crash
    # in request handling must not discard queue state, and a queue restart
    # must not drop every open connection.
    Supervisor.start_link(children, strategy: :one_for_one, name: ReviewQueue.Supervisor)
  end

  defp queue_opts do
    [
      lease_ttl: Application.get_env(:review_queue, :lease_ttl, :timer.minutes(5)),
      max_attempts: Application.get_env(:review_queue, :max_attempts, 3)
    ]
  end

  defp http_server do
    {Bandit, plug: ReviewQueue.Router, port: Application.get_env(:review_queue, :port, 4000)}
  end
end
