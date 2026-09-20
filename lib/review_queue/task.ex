defmodule ReviewQueue.Task do
  @moduledoc """
  A unit of annotation work and its lifecycle.

  A task moves `pending -> leased -> complete`, or back to `pending` when a
  lease lapses. Nothing else is reachable, and `transition/2` is the only way
  to move between states.
  """

  @enforce_keys [:id, :payload]
  defstruct [
    :id,
    :payload,
    :leased_by,
    :leased_at,
    :lease_expires_at,
    :completed_at,
    :result,
    priority: 0,
    state: :pending,
    attempts: 0
  ]

  @type state :: :pending | :leased | :complete

  @type t :: %__MODULE__{
          id: String.t(),
          payload: map(),
          priority: integer(),
          state: state(),
          attempts: non_neg_integer(),
          leased_by: String.t() | nil,
          leased_at: DateTime.t() | nil,
          lease_expires_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          result: map() | nil
        }

  @valid_transitions %{
    pending: [:leased],
    leased: [:complete, :pending],
    complete: []
  }

  @doc """
  Builds a task.

  ## Examples

      iex> task = ReviewQueue.Task.new("t1", %{text: "review this"}, priority: 5)
      iex> {task.state, task.priority, task.attempts}
      {:pending, 5, 0}
  """
  @spec new(String.t(), map(), keyword()) :: t()
  def new(id, payload, opts \\ []) when is_binary(id) and is_map(payload) do
    %__MODULE__{
      id: id,
      payload: payload,
      priority: Keyword.get(opts, :priority, 0)
    }
  end

  @doc """
  Whether a task may move from its current state to `target`.

  ## Examples

      iex> task = ReviewQueue.Task.new("t1", %{})
      iex> ReviewQueue.Task.can_transition?(task, :leased)
      true
      iex> ReviewQueue.Task.can_transition?(task, :complete)
      false
  """
  @spec can_transition?(t(), state()) :: boolean()
  def can_transition?(%__MODULE__{state: from}, target) do
    target in Map.fetch!(@valid_transitions, from)
  end

  @doc """
  Whether the lease has lapsed as of `now`.

  A task that is not leased is never expired.
  """
  @spec lease_expired?(t(), DateTime.t()) :: boolean()
  def lease_expired?(%__MODULE__{state: :leased, lease_expires_at: expiry}, now)
      when not is_nil(expiry) do
    DateTime.compare(now, expiry) == :gt
  end

  def lease_expired?(%__MODULE__{}, _now), do: false

  @doc "Grants `holder` a lease running until `expires_at`."
  @spec lease(t(), String.t(), DateTime.t(), DateTime.t()) :: t()
  def lease(%__MODULE__{} = task, holder, now, expires_at) do
    %{
      task
      | state: :leased,
        leased_by: holder,
        leased_at: now,
        lease_expires_at: expires_at,
        attempts: task.attempts + 1
    }
  end

  @doc "Marks a task complete, recording its result."
  @spec complete(t(), map(), DateTime.t()) :: t()
  def complete(%__MODULE__{} = task, result, now) do
    %{
      task
      | state: :complete,
        result: result,
        completed_at: now,
        leased_by: nil,
        lease_expires_at: nil
    }
  end

  @doc "Returns a task to the pending pool, clearing its lease."
  @spec release(t()) :: t()
  def release(%__MODULE__{} = task) do
    %{task | state: :pending, leased_by: nil, leased_at: nil, lease_expires_at: nil}
  end

  @doc """
  Sort key placing higher priority first, then earlier insertion.

  Priority is negated so the default ascending sort puts urgent work first,
  and the tuple's second element keeps equal priorities in FIFO order.
  """
  @spec sort_key(t(), non_neg_integer()) :: {integer(), non_neg_integer()}
  def sort_key(%__MODULE__{priority: priority}, sequence), do: {-priority, sequence}
end
