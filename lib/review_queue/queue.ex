defmodule ReviewQueue.Queue do
  @moduledoc """
  A lease-based work queue, held in a `GenServer` with ETS-backed storage.

  ## Why a GenServer rather than bare ETS

  Claiming a task is read-modify-write: find the highest-priority pending task,
  then mark it leased. Two annotators racing through raw ETS can both read the
  same task before either writes. Serialising writes through one process makes
  that race structurally impossible rather than merely unlikely — this is the
  BEAM's answer to a mutex, and it costs less than one.

  Reads that do not mutate (`stats/1`, `fetch/2`) go straight to ETS and skip
  the process entirely, so a dashboard polling for depth never queues behind a
  claim.

  ## Lease expiry

  Sweeping is lazy. Rather than a timer per task, expired leases are reaped
  whenever the queue is next touched. A thousand tasks means one sweep, not a
  thousand timers.
  """

  use GenServer

  require Logger

  alias ReviewQueue.Task, as: WorkTask

  @default_lease_ttl :timer.minutes(5)
  @default_max_attempts 3

  defmodule State do
    @moduledoc false
    defstruct [:table, :lease_ttl, :max_attempts, :clock, sequence: 0, expired_total: 0]
  end

  # ---------------------------------------------------------------- client --

  @doc """
  Starts the queue.

  ## Options

    * `:name` - registered name, defaults to `#{inspect(__MODULE__)}`
    * `:lease_ttl` - lease duration in milliseconds
    * `:max_attempts` - re-leases before a task is dropped; `0` for unlimited
    * `:clock` - zero-arity function returning the current `DateTime`, for tests
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Enqueues a task. Returns `{:error, :already_exists}` if it is live."
  @spec add(GenServer.server(), WorkTask.t()) :: :ok | {:error, :already_exists}
  def add(queue \\ __MODULE__, %WorkTask{} = task), do: GenServer.call(queue, {:add, task})

  @doc "Leases the highest-priority pending task to `holder`."
  @spec claim(GenServer.server(), String.t()) :: {:ok, WorkTask.t()} | {:error, :empty}
  def claim(queue \\ __MODULE__, holder) when is_binary(holder) do
    GenServer.call(queue, {:claim, holder})
  end

  @doc "Completes a leased task. Only the holder may submit, before expiry."
  @spec submit(GenServer.server(), String.t(), String.t(), map()) ::
          :ok | {:error, :not_found | :not_lease_holder | :lease_expired}
  def submit(queue \\ __MODULE__, id, holder, result) do
    GenServer.call(queue, {:submit, id, holder, result})
  end

  @doc "Extends a live lease, for a reviewer still working."
  @spec extend(GenServer.server(), String.t(), String.t()) ::
          {:ok, DateTime.t()} | {:error, :not_found | :not_lease_holder | :lease_expired}
  def extend(queue \\ __MODULE__, id, holder), do: GenServer.call(queue, {:extend, id, holder})

  @doc "Returns a leased task to the pool without completing it."
  @spec release(GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, :not_found | :not_lease_holder}
  def release(queue \\ __MODULE__, id, holder), do: GenServer.call(queue, {:release, id, holder})

  @doc """
  Fetches a task by id.

  Reads ETS directly rather than calling the server, so a polling dashboard
  never queues behind a claim.
  """
  @spec fetch(GenServer.server(), String.t()) :: {:ok, WorkTask.t()} | :error
  def fetch(queue \\ __MODULE__, id) do
    case :ets.lookup(table_for(queue), id) do
      [{^id, task}] -> {:ok, task}
      [] -> :error
    end
  end

  @doc "Counts tasks by state, sweeping expired leases first."
  @spec stats(GenServer.server()) :: %{
          pending: non_neg_integer(),
          leased: non_neg_integer(),
          complete: non_neg_integer(),
          expired_total: non_neg_integer()
        }
  def stats(queue \\ __MODULE__), do: GenServer.call(queue, :stats)

  # ---------------------------------------------------------------- server --

  @impl GenServer
  def init(opts) do
    # Two tables: the task store, and an ordered index of pending work.
    #
    # `read_concurrency` on the store because reads (fetch, dashboards) vastly
    # outnumber writes and must not contend with them.
    table =
      :ets.new(:review_queue_tasks, [
        :set,
        :protected,
        :named_table,
        read_concurrency: true
      ])

    # An `ordered_set` keyed by {-priority, sequence} means "next task to hand
    # out" is `:ets.first/1` — O(log n) with no scan and no re-sorting on
    # insert, which a plain list or a sorted-on-read set would both cost.
    :ets.new(:review_queue_order, [:ordered_set, :protected, :named_table])

    {:ok,
     %State{
       table: table,
       lease_ttl: Keyword.get(opts, :lease_ttl, @default_lease_ttl),
       max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
       clock: Keyword.get(opts, :clock, &DateTime.utc_now/0)
     }}
  end

  @impl GenServer
  def handle_call({:add, task}, _from, state) do
    case :ets.lookup(state.table, task.id) do
      [{_id, %WorkTask{state: existing}}] when existing != :pending ->
        {:reply, {:error, :already_exists}, state}

      _ ->
        sequence = state.sequence
        :ets.insert(state.table, {task.id, task})
        :ets.insert(:review_queue_order, {WorkTask.sort_key(task, sequence), task.id})
        {:reply, :ok, %{state | sequence: sequence + 1}}
    end
  end

  def handle_call({:claim, holder}, _from, state) do
    state = sweep(state)
    now = state.clock.()

    case next_pending(state) do
      nil ->
        {:reply, {:error, :empty}, state}

      {key, %WorkTask{} = task} ->
        expires_at = DateTime.add(now, state.lease_ttl, :millisecond)
        leased = WorkTask.lease(task, holder, now, expires_at)

        :ets.insert(state.table, {task.id, leased})
        :ets.delete(:review_queue_order, key)

        :telemetry.execute([:review_queue, :task, :claimed], %{count: 1}, %{
          task_id: task.id,
          holder: holder
        })

        {:reply, {:ok, leased}, state}
    end
  end

  def handle_call({:submit, id, holder, result}, _from, state) do
    with {:ok, task} <- lookup(state, id),
         :ok <- verify_holder(task, holder),
         :ok <- verify_live(task, state) do
      completed = WorkTask.complete(task, result, state.clock.())
      :ets.insert(state.table, {id, completed})

      :telemetry.execute([:review_queue, :task, :completed], %{count: 1}, %{
        task_id: id,
        holder: holder,
        attempts: completed.attempts
      })

      {:reply, :ok, state}
    else
      {:error, :lease_expired} ->
        # Expire it now so the work goes back to the pool rather than stranding.
        {:reply, {:error, :lease_expired}, expire(state, id)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:extend, id, holder}, _from, state) do
    with {:ok, task} <- lookup(state, id),
         :ok <- verify_holder(task, holder),
         :ok <- verify_live(task, state) do
      expires_at = DateTime.add(state.clock.(), state.lease_ttl, :millisecond)
      :ets.insert(state.table, {id, %{task | lease_expires_at: expires_at}})
      {:reply, {:ok, expires_at}, state}
    else
      {:error, :lease_expired} -> {:reply, {:error, :lease_expired}, expire(state, id)}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:release, id, holder}, _from, state) do
    with {:ok, task} <- lookup(state, id),
         :ok <- verify_holder(task, holder) do
      {:reply, :ok, requeue(state, task)}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call(:stats, _from, state) do
    state = sweep(state)

    counts =
      :ets.foldl(
        fn {_id, task}, acc -> Map.update(acc, task.state, 1, &(&1 + 1)) end,
        %{pending: 0, leased: 0, complete: 0},
        state.table
      )

    {:reply, Map.put(counts, :expired_total, state.expired_total), state}
  end

  # --------------------------------------------------------------- private --

  defp lookup(state, id) do
    case :ets.lookup(state.table, id) do
      [{^id, task}] -> {:ok, task}
      [] -> {:error, :not_found}
    end
  end

  defp verify_holder(%WorkTask{state: :leased, leased_by: holder}, holder), do: :ok
  defp verify_holder(%WorkTask{}, _holder), do: {:error, :not_lease_holder}

  defp verify_live(task, state) do
    if WorkTask.lease_expired?(task, state.clock.()),
      do: {:error, :lease_expired},
      else: :ok
  end

  defp next_pending(state) do
    # The order table is an ordered_set keyed by {-priority, sequence}, so the
    # first key is always the task to hand out next.
    case :ets.first(:review_queue_order) do
      :"$end_of_table" ->
        nil

      key ->
        [{^key, id}] = :ets.lookup(:review_queue_order, key)

        case lookup(state, id) do
          {:ok, %WorkTask{state: :pending} = task} ->
            {key, task}

          _ ->
            # Stale index entry; drop it and look again.
            :ets.delete(:review_queue_order, key)
            next_pending(state)
        end
    end
  end

  defp sweep(state) do
    now = state.clock.()

    :ets.foldl(
      fn {id, task}, acc ->
        if WorkTask.lease_expired?(task, now), do: expire(acc, id), else: acc
      end,
      state,
      state.table
    )
  end

  defp expire(state, id) do
    case lookup(state, id) do
      {:ok, task} ->
        state = %{state | expired_total: state.expired_total + 1}

        if state.max_attempts > 0 and task.attempts >= state.max_attempts do
          Logger.warning("dropping task #{id} after #{task.attempts} abandoned leases")

          :telemetry.execute([:review_queue, :task, :dropped], %{count: 1}, %{
            task_id: id,
            attempts: task.attempts
          })

          :ets.delete(state.table, id)
          state
        else
          requeue(state, task)
        end

      {:error, :not_found} ->
        state
    end
  end

  defp requeue(state, task) do
    released = WorkTask.release(task)
    sequence = state.sequence

    :ets.insert(state.table, {task.id, released})
    :ets.insert(:review_queue_order, {WorkTask.sort_key(released, sequence), task.id})

    %{state | sequence: sequence + 1}
  end

  # Tables are `:named_table`, so a direct read needs no server round trip
  # regardless of how the queue was registered.
  defp table_for(_queue), do: :review_queue_tasks
end
