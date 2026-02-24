defmodule BackoffRetry do
  @moduledoc """
  Functional retry with backoff for Elixir.

  `BackoffRetry` provides a simple `retry/2` function that executes a function
  and retries on failure using composable, stream-based backoff strategies.
  Zero macros, zero processes, injectable sleep for fast tests.

  ## Quick start

      # Retry with defaults (3 attempts, exponential backoff)
      {:ok, body} = BackoffRetry.retry(fn -> fetch(url) end)

      # With options
      {:ok, body} = BackoffRetry.retry(fn -> fetch(url) end,
        backoff: :exponential,
        max_attempts: 5,
        retry_if: fn
          {:error, :timeout} -> true
          {:error, :econnrefused} -> true
          _ -> false
        end,
        on_retry: fn attempt, delay, error ->
          Logger.warning("Attempt \#{attempt} failed: \#{inspect(error)}")
        end
      )

  ## Options

    * `:backoff` — `:exponential` (default), `:linear`, `:constant`, or any `Enumerable` of ms
    * `:base_delay` — initial delay in ms (default: `100`)
    * `:max_delay` — cap per-retry delay in ms (default: `5_000`)
    * `:max_attempts` — total attempts including first (default: `3`)
    * `:budget` — total time budget in ms (default: `:infinity`)
    * `:retry_if` — `fn {:error, reason} -> boolean end` (default: retries all errors)
    * `:on_retry` — `fn attempt, delay, error -> any` callback before sleep
    * `:sleep_fn` — sleep function, defaults to `Process.sleep/1`

  """

  defmodule Abort do
    @moduledoc """
    Wraps a reason to signal that retry should stop immediately.

    Return `{:error, BackoffRetry.abort(reason)}` from the retried function
    to abort without further attempts, regardless of `retry_if`.
    """
    defstruct [:reason]

    @type t :: %__MODULE__{reason: any()}
  end

  @type option ::
          {:backoff, :exponential | :linear | :constant | Enumerable.t()}
          | {:base_delay, non_neg_integer()}
          | {:max_delay, non_neg_integer()}
          | {:max_attempts, pos_integer()}
          | {:budget, :infinity | non_neg_integer()}
          | {:retry_if, (any() -> boolean())}
          | {:on_retry, (pos_integer(), non_neg_integer(), any() -> any())}
          | {:sleep_fn, (non_neg_integer() -> any())}

  @doc """
  Creates an `%Abort{}` struct to signal immediate retry termination.

  ## Example

      BackoffRetry.retry(fn ->
        case api_call() do
          {:error, :not_found} -> {:error, BackoffRetry.abort(:not_found)}
          other -> other
        end
      end)

  """
  @spec abort(any()) :: Abort.t()
  def abort(reason), do: %Abort{reason: reason}

  @doc """
  Executes `fun` and retries on failure with configurable backoff.

  See the module documentation for available options.
  """
  @spec retry((-> any()), [option()]) :: {:ok, any()} | {:error, any()}
  def retry(fun, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 3)
    retry_if = Keyword.get(opts, :retry_if, fn {:error, _} -> true end)
    on_retry = Keyword.get(opts, :on_retry)
    sleep_fn = Keyword.get(opts, :sleep_fn, &Process.sleep/1)
    budget = Keyword.get(opts, :budget, :infinity)

    delays = build_delays(opts, max_attempts)

    deadline =
      case budget do
        :infinity -> :infinity
        ms -> System.monotonic_time(:millisecond) + ms
      end

    ctx = %{
      fun: fun,
      retry_if: retry_if,
      on_retry: on_retry,
      sleep_fn: sleep_fn,
      deadline: deadline
    }

    do_retry(ctx, delays, 1)
  end

  defp do_retry(ctx, delays, attempt) do
    case execute(ctx.fun) do
      {:ok, value} ->
        {:ok, value}

      {:error, %Abort{reason: reason}} ->
        {:error, reason}

      {:error, reason} = error ->
        maybe_retry(ctx, delays, attempt, reason, error)
    end
  end

  defp maybe_retry(_ctx, [], _attempt, reason, _error), do: {:error, reason}

  defp maybe_retry(ctx, [delay | rest], attempt, reason, error) do
    cond do
      not ctx.retry_if.(error) ->
        {:error, reason}

      budget_exceeded?(ctx.deadline, delay) ->
        {:error, reason}

      true ->
        if ctx.on_retry, do: ctx.on_retry.(attempt, delay, error)
        ctx.sleep_fn.(delay)
        do_retry(ctx, rest, attempt + 1)
    end
  end

  defp execute(fun) do
    normalize(fun.())
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    :throw, value -> {:error, {:throw, value}}
  end

  defp normalize({:ok, value}), do: {:ok, value}
  defp normalize({:error, %Abort{}} = abort), do: abort
  defp normalize({:error, reason}), do: {:error, reason}
  defp normalize(:ok), do: {:ok, :ok}
  defp normalize(:error), do: {:error, :error}
  defp normalize(value), do: {:ok, value}

  defp build_delays(opts, max_attempts) do
    delays_stream = build_delay_stream(opts)

    delays_stream
    |> BackoffRetry.Backoff.cap(Keyword.get(opts, :max_delay, 5_000))
    |> Enum.take(max(max_attempts - 1, 0))
  end

  defp build_delay_stream(opts) do
    case Keyword.get(opts, :backoff, :exponential) do
      :exponential ->
        BackoffRetry.Backoff.exponential(base: Keyword.get(opts, :base_delay, 100))

      :linear ->
        BackoffRetry.Backoff.linear(base: Keyword.get(opts, :base_delay, 100))

      :constant ->
        BackoffRetry.Backoff.constant(delay: Keyword.get(opts, :base_delay, 100))

      delays when is_list(delays) ->
        delays

      %Stream{} = stream ->
        stream

      enumerable ->
        enumerable
    end
  end

  defp budget_exceeded?(:infinity, _delay), do: false

  defp budget_exceeded?(deadline, delay) do
    System.monotonic_time(:millisecond) + delay > deadline
  end
end
