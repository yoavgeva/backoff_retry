# BackoffRetry

> **Deprecated** — This package has been merged into [`resiliency`](https://github.com/yoavgeva/resiliency).
> Use `Resiliency.BackoffRetry` instead. This repo is archived and will not receive further updates.

[![Hex](https://img.shields.io/hexpm/v/backoff_retry.svg)](https://hex.pm/packages/backoff_retry)
[![CI](https://github.com/yoavgeva/backoff_retry/actions/workflows/ci.yml/badge.svg)](https://github.com/yoavgeva/backoff_retry/actions/workflows/ci.yml)

> 87 tests, zero warnings, Dialyzer + Credo strict clean.

Functional retry with backoff for Elixir — composable strategies, zero macros, injectable sleep.

## Design goals

We felt something was missing in existing Elixir retry solutions, so we built what we wanted:

- **Full error context** — `retry_if` and `on_retry` receive the complete `{:error, reason}` tuple, including exceptions, exits, throws, and 3-element tuples
- **Composable** — pure functions and streams, no macros. Wrap, pipeline, pass as args
- **Testable** — injectable `sleep_fn` for instant test suites
- **Stack trace preservation** — `reraise: true` re-raises with the original stacktrace
- **Abort** — `abort/1` stops retries immediately, regardless of `retry_if`
- **Time budget** — `budget` option uses monotonic time
- **Callbacks** — `on_retry` with attempt number, delay, and error

Inspired by Rust's `backon`, Go's `cenkalti/backoff`, and Python's `tenacity`.

## Installation

```elixir
def deps do
  [{:backoff_retry, "~> 0.1.0"}]
end
```

## Quick start

```elixir
# Simple — defaults to 3 attempts with exponential backoff:
# BackoffRetry.retry(fn -> fetch(url) end)

# With options:
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
| `{:error, reason, metadata}` | `{:error, {reason, metadata}}` |

The `retry_if` predicate always receives `{:error, reason}` for a uniform interface.

### Preserving stack traces

By default, rescued exceptions are returned as `{:error, exception}`. Pass `reraise: true` to re-raise the exception with its original stacktrace when retries are exhausted:

```elixir
# Raises the original exception with the original stacktrace after 3 failed attempts
BackoffRetry.retry(fn -> might_raise() end,
  max_attempts: 3,
  reraise: true
)
```

This only applies to rescued exceptions. Non-exception errors like `{:error, :timeout}` are still returned as tuples regardless of this option.

## Return values

| Scenario | Return |
|---|---|
| Function succeeds | `{:ok, value}` |
| Bare value (e.g. `42`) | `{:ok, 42}` |
| `:ok` | `{:ok, :ok}` |
| `{:error, reason, metadata}` (3-tuple) | `{:error, {reason, metadata}}` |
| All attempts exhausted | `{:error, reason}` (last error) |
| All attempts exhausted + `reraise: true` | Re-raises exception with original stacktrace |
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
| `budget` | `:infinity` | Total time budget in ms (monotonic) |
| `retry_if` | retries all errors | `fn {:error, reason} -> boolean` |
| `on_retry` | `nil` | `fn attempt, delay, error -> any` |
| `sleep_fn` | `Process.sleep/1` | For testing |
| `reraise` | `false` | Re-raise rescued exceptions with original stacktrace on exhaustion |

## How it works

1. Parse options, build a finite list of delays from the backoff stream (take `max_attempts - 1`)
2. Execute the function inside try/rescue/catch
3. On success, return `{:ok, value}`
4. On `{:error, %Abort{}}`, return `{:error, reason}` immediately
5. On `{:error, _}`, check `retry_if`, check budget, call `on_retry`, sleep, recurse
6. No more delays, return `{:error, last_error}` (or re-raise if `reraise: true`)

No GenServer, no supervision tree, no macros. Just a recursive function with a list of delays.

## License

MIT
