# BackoffRetry

[![Hex](https://img.shields.io/hexpm/v/backoff_retry.svg)](https://hex.pm/packages/backoff_retry)
[![CI](https://github.com/yoavgeva/backoff_retry/actions/workflows/ci.yml/badge.svg)](https://github.com/yoavgeva/backoff_retry/actions/workflows/ci.yml)

Functional retry with backoff for Elixir — composable strategies, zero macros, injectable sleep.

## Why?

The dominant Elixir retry library uses macros, which causes real problems:

- **Inflexible error matching** — cannot selectively retry `{:error, :timeout}` but not `{:error, :not_found}`
- **Cannot compose in pipelines** — macro requires `do/after/else` block syntax
- **Hard to wrap/abstract** — cannot build `with_retry(fun, strategy)` since macro expects literal blocks
- **No per-retry callbacks** — no hooks for logging/telemetry between attempts
- **Hard to test** — no way to inject mock sleep

BackoffRetry takes a different approach: **pure functions + streams**, inspired by Rust's `backon`, Go's `cenkalti/backoff`, and Python's `tenacity`.

- Zero macros, zero processes
- `retry_if` receives the full `{:error, reason}` tuple for precise matching
- Composable backoff strategies via standard Elixir streams
- `on_retry` callback for logging/telemetry
- Injectable `sleep_fn` for instant tests
- `abort/1` to bail out immediately on non-retryable errors

## Installation

```elixir
def deps do
  [{:backoff_retry, "~> 0.1.0"}]
end
```

## Quick start

```elixir
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
    Logger.warning("Attempt #{attempt} failed: #{inspect(error)}, retrying in #{delay}ms")
  end
)
```

## Backoff strategies

Strategies are infinite streams of delay values in milliseconds. They compose naturally with pipes:

```elixir
# Exponential: 100, 200, 400, 800, ...
BackoffRetry.Backoff.exponential()

# Linear: 100, 200, 300, 400, ...
BackoffRetry.Backoff.linear()

# Constant: 100, 100, 100, ...
BackoffRetry.Backoff.constant()

# Compose with jitter and cap
BackoffRetry.Backoff.exponential(base: 200, multiplier: 2)
|> BackoffRetry.Backoff.jitter(0.25)    # +-25% random variance
|> BackoffRetry.Backoff.cap(10_000)      # max 10s per retry

# Or just pass a plain list
BackoffRetry.retry(fn -> api_call() end, backoff: [100, 500, 1_000, 5_000])
```

## Real-world examples

### HTTP retry with selective matching

```elixir
BackoffRetry.retry(
  fn -> HTTPClient.get(url) end,
  max_attempts: 5,
  retry_if: fn
    {:error, :timeout} -> true
    {:error, :econnrefused} -> true
    {:error, %{status: status}} when status >= 500 -> true
    _ -> false
  end,
  on_retry: fn attempt, delay, error ->
    Logger.warning("HTTP attempt #{attempt} failed: #{inspect(error)}")
  end
)
```

### Database reconnection with budget

```elixir
BackoffRetry.retry(
  fn -> Repo.query("SELECT 1") end,
  backoff: :exponential,
  max_attempts: 20,
  budget: 30_000,  # give up after 30s total
  base_delay: 100,
  max_delay: 5_000
)
```

### Abort on non-retryable errors

```elixir
BackoffRetry.retry(fn ->
  case API.get_resource(id) do
    {:error, :not_found} -> {:error, BackoffRetry.abort(:not_found)}
    {:error, :forbidden} -> {:error, BackoffRetry.abort(:forbidden)}
    other -> other
  end
end)
```

## Error handling

Raises, exits, and throws are all captured and converted to `{:error, _}` tuples:

| Source | Wrapped as |
|---|---|
| `raise "boom"` | `{:error, %RuntimeError{message: "boom"}}` |
| `exit(:reason)` | `{:error, {:exit, :reason}}` |
| `throw(:value)` | `{:error, {:throw, :value}}` |

The `retry_if` predicate always receives `{:error, reason}` for a uniform interface.

## Return values

| Scenario | Return |
|---|---|
| Function succeeds | `{:ok, value}` |
| Bare value (e.g. `42`) | `{:ok, 42}` |
| `:ok` | `{:ok, :ok}` |
| All attempts exhausted | `{:error, reason}` (last error) |
| Budget exceeded | `{:error, reason}` (last error) |
| Abort | `{:error, reason}` (unwrapped) |
| `retry_if` returns false | `{:error, reason}` |

## Options

| Option | Default | Description |
|---|---|---|
| `backoff` | `:exponential` | `:exponential`, `:linear`, `:constant`, or any `Enumerable` of ms |
| `base_delay` | `100` | Initial delay in ms |
| `max_delay` | `5_000` | Cap per-retry delay in ms |
| `max_attempts` | `3` | Total attempts including first |
| `budget` | `:infinity` | Total time budget in ms |
| `retry_if` | retries all errors | `fn {:error, reason} -> boolean` |
| `on_retry` | `nil` | `fn attempt, delay, error -> any` |
| `sleep_fn` | `Process.sleep/1` | For testing |

## How it works

1. Parse options, build a finite list of delays from the backoff stream (take `max_attempts - 1`)
2. Execute the function inside try/rescue/catch
3. On success, return `{:ok, value}`
4. On `{:error, %Abort{}}`, return `{:error, reason}` immediately
5. On `{:error, _}`, check `retry_if`, check budget, call `on_retry`, sleep, recurse
6. No more delays, return `{:error, last_error}`

No GenServer, no supervision tree, no macros. Just a recursive function with a list of delays.

## Comparison

| Feature | BackoffRetry | ElixirRetry |
|---|---|---|
| API style | Function | Macro |
| Error matching | Full `{:error, reason}` | Atoms only |
| Pipeline friendly | Yes | No |
| Composable strategies | Stream pipes | Delay streams |
| Per-retry callbacks | `on_retry` | No |
| Abort mechanism | `abort/1` | No |
| Testable sleep | `sleep_fn` option | No |
| Captures raise/exit/throw | Yes | Partial |

## License

MIT
