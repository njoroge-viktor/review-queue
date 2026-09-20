defmodule ReviewQueue.QueueTest do
  use ExUnit.Case, async: false

  alias ReviewQueue.Queue
  alias ReviewQueue.Task, as: WorkTask
  alias ReviewQueue.TestClock

  setup do
    {:ok, clock} = TestClock.start_link()

    # Named ETS tables mean one queue per node, so the supervised instance is
    # stopped for the duration and restored afterwards.
    Supervisor.terminate_child(ReviewQueue.Supervisor, ReviewQueue.Queue)

    {:ok, queue} =
      Queue.start_link(
        name: :"queue_#{System.unique_integer([:positive])}",
        lease_ttl: :timer.minutes(1),
        max_attempts: 3,
        clock: TestClock.fun(clock)
      )

    on_exit(fn ->
      if Process.alive?(queue), do: GenServer.stop(queue)
      Supervisor.restart_child(ReviewQueue.Supervisor, ReviewQueue.Queue)
    end)

    %{queue: queue, clock: clock}
  end

  defp add(queue, id, priority \\ 0) do
    :ok = Queue.add(queue, WorkTask.new(id, %{"text" => id}, priority: priority))
  end

  describe "add/2 and claim/2" do
    test "a claimed task carries its holder and first attempt", %{queue: q} do
      add(q, "t1")

      assert {:ok, task} = Queue.claim(q, "ann-a")
      assert task.id == "t1"
      assert task.leased_by == "ann-a"
      assert task.attempts == 1
    end

    test "an empty queue reports :empty", %{queue: q} do
      assert {:error, :empty} = Queue.claim(q, "ann-a")
    end

    test "a leased task is not handed to a second annotator", %{queue: q} do
      add(q, "t1")
      assert {:ok, _} = Queue.claim(q, "ann-a")
      assert {:error, :empty} = Queue.claim(q, "ann-b")
    end

    test "re-adding a leased id is rejected", %{queue: q} do
      add(q, "t1")
      Queue.claim(q, "ann-a")

      assert {:error, :already_exists} =
               Queue.add(q, WorkTask.new("t1", %{}))
    end
  end

  describe "priority ordering" do
    test "higher priority is handed out first", %{queue: q} do
      add(q, "low", 1)
      add(q, "urgent", 10)
      add(q, "mid", 5)

      assert {:ok, %{id: "urgent"}} = Queue.claim(q, "ann-a")
      assert {:ok, %{id: "mid"}} = Queue.claim(q, "ann-a")
      assert {:ok, %{id: "low"}} = Queue.claim(q, "ann-a")
    end

    test "equal priorities are FIFO", %{queue: q} do
      for id <- ~w(first second third), do: add(q, id, 5)

      assert {:ok, %{id: "first"}} = Queue.claim(q, "ann-a")
      assert {:ok, %{id: "second"}} = Queue.claim(q, "ann-a")
      assert {:ok, %{id: "third"}} = Queue.claim(q, "ann-a")
    end
  end

  describe "submit/4" do
    test "completes the task and stores its result", %{queue: q} do
      add(q, "t1")
      Queue.claim(q, "ann-a")

      assert :ok = Queue.submit(q, "t1", "ann-a", %{"label" => "safe"})
      assert {:ok, task} = Queue.fetch(q, "t1")
      assert task.state == :complete
      assert task.result == %{"label" => "safe"}
    end

    test "a non-holder cannot submit", %{queue: q} do
      add(q, "t1")
      Queue.claim(q, "ann-a")

      # Accepting this would silently overwrite the real holder's work.
      assert {:error, :not_lease_holder} = Queue.submit(q, "t1", "ann-b", %{})
    end

    test "an unknown id is not found", %{queue: q} do
      assert {:error, :not_found} = Queue.submit(q, "ghost", "ann-a", %{})
    end

    test "a pending task cannot be submitted", %{queue: q} do
      add(q, "t1")
      assert {:error, :not_lease_holder} = Queue.submit(q, "t1", "ann-a", %{})
    end
  end

  describe "lease expiry" do
    test "an abandoned task returns to the pool", %{queue: q, clock: clock} do
      add(q, "t1")
      Queue.claim(q, "ann-a")

      TestClock.advance(clock, :timer.minutes(2))

      assert {:ok, task} = Queue.claim(q, "ann-b")
      assert task.id == "t1"
      assert task.leased_by == "ann-b"
      assert task.attempts == 2
    end

    test "a submission after expiry is rejected and the task requeued", %{
      queue: q,
      clock: clock
    } do
      add(q, "t1")
      Queue.claim(q, "ann-a")
      TestClock.advance(clock, :timer.minutes(2))

      assert {:error, :lease_expired} = Queue.submit(q, "t1", "ann-a", %{"late" => true})
      assert %{pending: 1} = Queue.stats(q)
    end

    test "extend keeps a lease alive", %{queue: q, clock: clock} do
      add(q, "t1")
      Queue.claim(q, "ann-a")

      TestClock.advance(clock, :timer.seconds(50))
      assert {:ok, _expires} = Queue.extend(q, "t1", "ann-a")

      TestClock.advance(clock, :timer.seconds(50))
      assert :ok = Queue.submit(q, "t1", "ann-a", %{})
    end

    test "extend by a non-holder is rejected", %{queue: q} do
      add(q, "t1")
      Queue.claim(q, "ann-a")

      assert {:error, :not_lease_holder} = Queue.extend(q, "t1", "ann-b")
    end

    test "a task that defeats max_attempts annotators is dropped", %{queue: q, clock: clock} do
      add(q, "poison")

      for holder <- ~w(ann-a ann-b ann-c) do
        assert {:ok, _} = Queue.claim(q, holder)
        TestClock.advance(clock, :timer.minutes(2))
      end

      # A task nobody can finish is a data problem, not a scheduling one.
      assert {:error, :empty} = Queue.claim(q, "ann-d")
      assert %{pending: 0} = Queue.stats(q)
    end
  end

  describe "release/3" do
    test "returns a task immediately", %{queue: q} do
      add(q, "t1")
      Queue.claim(q, "ann-a")

      assert :ok = Queue.release(q, "t1", "ann-a")
      assert {:ok, %{id: "t1"}} = Queue.claim(q, "ann-b")
    end

    test "a non-holder cannot release", %{queue: q} do
      add(q, "t1")
      Queue.claim(q, "ann-a")

      assert {:error, :not_lease_holder} = Queue.release(q, "t1", "ann-b")
    end
  end

  describe "stats/1" do
    test "counts each state", %{queue: q} do
      add(q, "pending-one")
      add(q, "leased-one")
      add(q, "done-one")

      {:ok, _} = Queue.claim(q, "ann-a")
      {:ok, second} = Queue.claim(q, "ann-b")
      :ok = Queue.submit(q, second.id, "ann-b", %{})

      assert %{pending: 1, leased: 1, complete: 1} = Queue.stats(q)
    end
  end

  describe "fetch/2" do
    test "reads without a server round trip", %{queue: q} do
      add(q, "t1")
      assert {:ok, %{id: "t1", state: :pending}} = Queue.fetch(q, "t1")
    end

    test "reports :error for an unknown id", %{queue: q} do
      assert :error = Queue.fetch(q, "ghost")
    end
  end

  describe "concurrency" do
    test "no task is ever handed to two annotators", %{queue: q} do
      for i <- 1..200, do: add(q, "t#{String.pad_leading(to_string(i), 3, "0")}", rem(i, 5))

      claimed =
        1..16
        |> Task.async_stream(
          fn worker ->
            Stream.repeatedly(fn -> Queue.claim(q, "ann-#{worker}") end)
            |> Enum.take_while(&match?({:ok, _}, &1))
            |> Enum.map(fn {:ok, task} -> task.id end)
          end,
          max_concurrency: 16,
          timeout: 10_000
        )
        |> Enum.flat_map(fn {:ok, ids} -> ids end)

      # Serialising writes through the GenServer makes a double-claim
      # structurally impossible, not merely unlikely.
      assert length(claimed) == 200
      assert length(Enum.uniq(claimed)) == 200
    end
  end
end
