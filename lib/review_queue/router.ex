defmodule ReviewQueue.Router do
  @moduledoc """
  HTTP interface.

  Every endpoint returns the same error shape, so a client needs one code path:

      {"error": "not_lease_holder", "message": "..."}
  """

  use Plug.Router

  alias ReviewQueue.Queue
  alias ReviewQueue.Task, as: WorkTask

  # 1 MiB cap: without one, a single client can exhaust memory by streaming an
  # endless body.
  @max_body_bytes 1_000_000

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: @max_body_bytes
  )

  plug(:dispatch)

  get "/healthz" do
    send_json(conn, 200, %{status: "ok"})
  end

  get "/stats" do
    send_json(conn, 200, Queue.stats())
  end

  post "/v1/tasks" do
    with {:ok, id} <- require_param(conn.body_params, "id"),
         task <-
           WorkTask.new(id, Map.get(conn.body_params, "payload", %{}),
             priority: Map.get(conn.body_params, "priority", 0)
           ),
         :ok <- Queue.add(task) do
      send_json(conn, 201, %{id: id, state: "pending"})
    else
      {:error, :already_exists} ->
        send_error(conn, 409, :already_exists, "a live task with this id already exists")

      {:error, {:missing, field}} ->
        send_error(conn, 400, :invalid_request, "#{field} is required")
    end
  end

  post "/v1/tasks/claim" do
    with {:ok, holder} <- require_actor(conn),
         {:ok, task} <- Queue.claim(holder) do
      send_json(conn, 200, render_task(task))
    else
      {:error, :empty} -> send_json(conn, 204, nil)
      error -> send_queue_error(conn, error)
    end
  end

  post "/v1/tasks/:id/submit" do
    with {:ok, holder} <- require_actor(conn),
         :ok <- Queue.submit(id, holder, Map.get(conn.body_params, "result", %{})) do
      send_json(conn, 200, %{state: "complete"})
    else
      error -> send_queue_error(conn, error)
    end
  end

  post "/v1/tasks/:id/extend" do
    with {:ok, holder} <- require_actor(conn),
         {:ok, expires_at} <- Queue.extend(id, holder) do
      send_json(conn, 200, %{expires_at: expires_at})
    else
      error -> send_queue_error(conn, error)
    end
  end

  post "/v1/tasks/:id/release" do
    with {:ok, holder} <- require_actor(conn),
         :ok <- Queue.release(id, holder) do
      send_json(conn, 200, %{state: "pending"})
    else
      error -> send_queue_error(conn, error)
    end
  end

  get "/v1/tasks/:id" do
    case Queue.fetch(id) do
      {:ok, task} -> send_json(conn, 200, render_task(task))
      :error -> send_error(conn, 404, :not_found, "no task with that id")
    end
  end

  match _ do
    send_error(conn, 404, :not_found, "no such route")
  end

  # --------------------------------------------------------------- helpers --

  defp require_actor(conn) do
    case get_req_header(conn, "x-annotator-id") do
      [actor | _] when actor != "" -> {:ok, actor}
      _ -> {:error, :unauthenticated}
    end
  end

  defp require_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp render_task(%WorkTask{} = task) do
    %{
      id: task.id,
      payload: task.payload,
      priority: task.priority,
      state: task.state,
      attempts: task.attempts,
      leased_by: task.leased_by,
      lease_expires_at: task.lease_expires_at,
      result: task.result
    }
  end

  defp send_queue_error(conn, {:error, reason}) do
    {status, message} =
      case reason do
        :unauthenticated -> {401, "x-annotator-id header is required"}
        :not_found -> {404, "no task with that id"}
        :not_lease_holder -> {403, "caller does not hold this lease"}
        :lease_expired -> {409, "the lease has expired and the task was requeued"}
      end

    send_error(conn, status, reason, message)
  end

  defp send_json(conn, status, nil) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, "")
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp send_error(conn, status, reason, message) do
    send_json(conn, status, %{error: reason, message: message})
  end
end
