defmodule ReviewQueue.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ReviewQueue.Router

  @opts Router.init([])

  setup do
    # Reset the supervised queue between tests so counts start from zero.
    Supervisor.terminate_child(ReviewQueue.Supervisor, ReviewQueue.Queue)
    {:ok, _} = Supervisor.restart_child(ReviewQueue.Supervisor, ReviewQueue.Queue)
    :ok
  end

  defp request(method, path, body \\ nil, actor \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          method
          |> conn(path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn = if actor, do: put_req_header(conn, "x-annotator-id", actor), else: conn
    Router.call(conn, @opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  describe "GET /healthz" do
    test "is unauthenticated" do
      conn = request(:get, "/healthz")

      assert conn.status == 200
      assert json(conn) == %{"status" => "ok"}
    end
  end

  describe "authentication" do
    test "claiming without an annotator header is rejected" do
      conn = request(:post, "/v1/tasks/claim")

      assert conn.status == 401
      assert json(conn)["error"] == "unauthenticated"
    end

    test "an empty annotator header is rejected" do
      conn =
        :post
        |> conn("/v1/tasks/claim")
        |> put_req_header("x-annotator-id", "")
        |> Router.call(@opts)

      assert conn.status == 401
    end
  end

  describe "task lifecycle" do
    test "create, claim, submit, read back" do
      create =
        request(:post, "/v1/tasks", %{id: "t1", payload: %{text: "review"}, priority: 5}, "admin")

      assert create.status == 201

      claim = request(:post, "/v1/tasks/claim", nil, "ann-a")
      assert claim.status == 200
      assert json(claim)["id"] == "t1"
      assert json(claim)["attempts"] == 1

      submit = request(:post, "/v1/tasks/t1/submit", %{result: %{label: "safe"}}, "ann-a")
      assert submit.status == 200

      read = request(:get, "/v1/tasks/t1", nil, "admin")
      assert json(read)["state"] == "complete"
      assert json(read)["result"] == %{"label" => "safe"}
    end

    test "claiming an empty queue returns 204 with no body" do
      conn = request(:post, "/v1/tasks/claim", nil, "ann-a")

      assert conn.status == 204
      assert conn.resp_body == ""
    end

    test "a task without an id is rejected" do
      conn = request(:post, "/v1/tasks", %{priority: 1}, "admin")

      assert conn.status == 400
      assert json(conn)["error"] == "invalid_request"
    end

    test "a duplicate live id conflicts" do
      request(:post, "/v1/tasks", %{id: "t1"}, "admin")
      request(:post, "/v1/tasks/claim", nil, "ann-a")

      conn = request(:post, "/v1/tasks", %{id: "t1"}, "admin")
      assert conn.status == 409
      assert json(conn)["error"] == "already_exists"
    end

    test "submitting as a non-holder is forbidden" do
      request(:post, "/v1/tasks", %{id: "t1"}, "admin")
      request(:post, "/v1/tasks/claim", nil, "ann-a")

      conn = request(:post, "/v1/tasks/t1/submit", %{result: %{}}, "ann-b")
      assert conn.status == 403
      assert json(conn)["error"] == "not_lease_holder"
    end

    test "release returns the task to the pool" do
      request(:post, "/v1/tasks", %{id: "t1"}, "admin")
      request(:post, "/v1/tasks/claim", nil, "ann-a")

      release = request(:post, "/v1/tasks/t1/release", nil, "ann-a")
      assert release.status == 200

      reclaim = request(:post, "/v1/tasks/claim", nil, "ann-b")
      assert reclaim.status == 200
    end

    test "extend renews the lease" do
      request(:post, "/v1/tasks", %{id: "t1"}, "admin")
      request(:post, "/v1/tasks/claim", nil, "ann-a")

      conn = request(:post, "/v1/tasks/t1/extend", nil, "ann-a")
      assert conn.status == 200
      assert json(conn)["expires_at"]
    end

    test "an unknown task is 404" do
      conn = request(:get, "/v1/tasks/ghost", nil, "admin")

      assert conn.status == 404
      assert json(conn)["error"] == "not_found"
    end
  end

  describe "GET /stats" do
    test "reflects queue depth" do
      request(:post, "/v1/tasks", %{id: "t1"}, "admin")
      request(:post, "/v1/tasks", %{id: "t2"}, "admin")
      request(:post, "/v1/tasks/claim", nil, "ann-a")

      stats = json(request(:get, "/stats"))
      assert stats["pending"] == 1
      assert stats["leased"] == 1
    end
  end

  describe "error shape" do
    test "every error carries the same two keys" do
      for conn <- [
            request(:post, "/v1/tasks/claim"),
            request(:get, "/v1/tasks/ghost", nil, "admin"),
            request(:get, "/no/such/route")
          ] do
        body = json(conn)
        assert Map.has_key?(body, "error")
        assert Map.has_key?(body, "message")
      end
    end

    test "an unknown route is 404" do
      assert request(:get, "/no/such/route").status == 404
    end
  end
end
