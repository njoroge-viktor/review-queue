defmodule ReviewQueue.TaskTest do
  use ExUnit.Case, async: true

  alias ReviewQueue.Task, as: WorkTask

  doctest ReviewQueue.Task

  describe "new/3" do
    test "starts pending with no attempts" do
      task = WorkTask.new("t1", %{text: "review"})

      assert task.state == :pending
      assert task.attempts == 0
      assert task.leased_by == nil
    end

    test "accepts a priority" do
      assert WorkTask.new("t1", %{}, priority: 9).priority == 9
    end

    test "rejects a non-binary id" do
      assert_raise FunctionClauseError, fn -> WorkTask.new(:atom_id, %{}) end
    end
  end

  describe "can_transition?/2" do
    test "pending may only become leased" do
      task = WorkTask.new("t1", %{})

      assert WorkTask.can_transition?(task, :leased)
      refute WorkTask.can_transition?(task, :complete)
    end

    test "leased may complete or return to pending" do
      task = %{WorkTask.new("t1", %{}) | state: :leased}

      assert WorkTask.can_transition?(task, :complete)
      assert WorkTask.can_transition?(task, :pending)
    end

    test "complete is terminal" do
      task = %{WorkTask.new("t1", %{}) | state: :complete}

      refute WorkTask.can_transition?(task, :pending)
      refute WorkTask.can_transition?(task, :leased)
    end
  end

  describe "lease/4" do
    test "records the holder and increments attempts" do
      now = ~U[2026-01-01 00:00:00Z]
      expires = DateTime.add(now, 300, :second)

      task = "t1" |> WorkTask.new(%{}) |> WorkTask.lease("ann-a", now, expires)

      assert task.state == :leased
      assert task.leased_by == "ann-a"
      assert task.attempts == 1
    end

    test "attempts accumulate across re-leases" do
      now = ~U[2026-01-01 00:00:00Z]
      expires = DateTime.add(now, 300, :second)

      task =
        "t1"
        |> WorkTask.new(%{})
        |> WorkTask.lease("ann-a", now, expires)
        |> WorkTask.release()
        |> WorkTask.lease("ann-b", now, expires)

      assert task.attempts == 2
    end
  end

  describe "lease_expired?/2" do
    setup do
      now = ~U[2026-01-01 00:00:00Z]
      expires = DateTime.add(now, 60, :second)
      %{task: WorkTask.lease(WorkTask.new("t1", %{}), "ann-a", now, expires), now: now}
    end

    test "false before expiry", %{task: task, now: now} do
      refute WorkTask.lease_expired?(task, DateTime.add(now, 30, :second))
    end

    test "false exactly at expiry", %{task: task, now: now} do
      refute WorkTask.lease_expired?(task, DateTime.add(now, 60, :second))
    end

    test "true after expiry", %{task: task, now: now} do
      assert WorkTask.lease_expired?(task, DateTime.add(now, 61, :second))
    end

    test "a pending task is never expired" do
      refute WorkTask.lease_expired?(WorkTask.new("t1", %{}), ~U[2099-01-01 00:00:00Z])
    end
  end

  describe "complete/3" do
    test "stores the result and clears the lease" do
      now = ~U[2026-01-01 00:00:00Z]

      task =
        "t1"
        |> WorkTask.new(%{})
        |> WorkTask.lease("ann-a", now, DateTime.add(now, 60, :second))
        |> WorkTask.complete(%{"label" => "safe"}, now)

      assert task.state == :complete
      assert task.result == %{"label" => "safe"}
      assert task.leased_by == nil
    end
  end

  describe "sort_key/2" do
    test "higher priority sorts first" do
      urgent = WorkTask.sort_key(WorkTask.new("a", %{}, priority: 10), 1)
      routine = WorkTask.sort_key(WorkTask.new("b", %{}, priority: 1), 0)

      assert urgent < routine
    end

    test "equal priorities stay FIFO" do
      first = WorkTask.sort_key(WorkTask.new("a", %{}, priority: 5), 0)
      second = WorkTask.sort_key(WorkTask.new("b", %{}, priority: 5), 1)

      assert first < second
    end
  end
end
