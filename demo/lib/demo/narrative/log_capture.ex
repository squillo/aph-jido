defmodule Demo.Narrative.LogCapture do
  @moduledoc """
  Routes the demo's own `Logger` output into the narrative instead of onto
  the console, so `mix demo.run` produces a transcript whose lines are in
  leg order rather than interleaved with the story that explains them.

  ## Why a `:logger` handler rather than console output

  The narrative is written with `IO.puts` from the task process; the guard
  logs from whichever process is handling the signal. Nothing orders those
  two streams against each other, so a plain console run would scatter
  `aph_guard:` lines through the prose at unpredictable points — and a
  transcript that reorders itself between runs cannot be a golden-output
  test (PRD-001 T11) nor a committed artifact (docs/transcripts/demo_run.txt).

  So: a custom `:logger` handler collects the demo's log events, the OTP
  `:default` console handler is silenced for the duration, and each leg
  renders the events it produced inline, verbatim.

  ## What is collected, and what is deliberately not

  Only events emitted from one of `@collected_modules` — `JidoAph.Guard` and
  `Demo.Actions.DeliverReply`, the two modules whose output IS the demo.
  Everything else is dropped at the handler, which is load-bearing rather
  than cosmetic: `Jido.AgentServer` logs its own `[error] ...
  [plugin_prepare_signal]` line for a refused hook AFTER it has already
  replied to the `Jido.AgentServer.call/2` caller (observed live, and
  recorded in the T10 refusal-matrix notes; it comes from
  `Jido.AgentServer.ErrorPolicy.log_error/3`). Dropping it at the handler
  means a straggler can never drift into the NEXT leg's block. The
  transcript says out loud that the framework emits that line.

  The emitting module is read from the event's `:mfa` metadata, NOT from a
  `:module` key — checked against a live handler rather than assumed:
  Elixir's `Logger` macros stamp `%{mfa: {Mod, fun, arity}, file: ..., line:
  ..., application: ..., domain: [:elixir]}` and no `:module` key at all, so
  a `meta[:module]` filter silently matches nothing and collects an empty
  transcript.

  ## Ordering guarantees this leans on

  `Jido.AgentServer` runs the whole hook -> route -> action chain inside one
  task process (`start_signal_call_task/3` in
  deps/jido/lib/jido/agent_server.ex) and only then sends the result back to
  the server, which replies to the caller. A `:logger` handler callback runs
  synchronously in the process that logged, so all of a leg's events are
  sent from that one task process, in emission order, before the call
  returns. `drain/0` therefore observes a complete, correctly-ordered leg;
  its timeouts exist to survive a slow scheduler, not to paper over a race.
  """

  @handler_id :demo_narrative_log_capture

  # The demo's own voices. Both are `require Logger` call sites, so their
  # events carry `:mfa` metadata naming the module (set by the Logger macros).
  @collected_modules [JidoAph.Guard, Demo.Actions.DeliverReply]

  # First message of a leg: generous, because the only reason it would not
  # already be in the mailbox is scheduler delay. Subsequent messages: short,
  # because they were sent back-to-back from the same process.
  @first_timeout_ms 1_000
  @rest_timeout_ms 100

  @typedoc """
  One collected event: a demo log line, or the report
  `Demo.Actions.DeliverReply` sends when it runs.
  """
  @type event ::
          {:log, Logger.level() | atom(), String.t()}
          | {:action, map(), map()}

  @typedoc """
  Opaque token returned by `install/1` and required by `uninstall/1`: the
  console handler's level as it was found, so it can be put back exactly.
  """
  @opaque console_token :: {:console, atom()} | :no_console

  @doc """
  Installs the collecting handler and silences the console for the duration.

  Events are sent to `collector_pid` as `t:event/0` messages. Returns the
  token `uninstall/1` needs to restore the console handler; callers must
  pair the two in an `after` block so a crash mid-narrative cannot leave the
  VM silent.
  """
  @spec install(pid()) :: console_token()
  def install(collector_pid) when is_pid(collector_pid) do
    :ok =
      :logger.add_handler(@handler_id, __MODULE__, %{
        level: :all,
        config: %{collector: collector_pid, modules: @collected_modules}
      })

    silence_console()
  end

  @doc """
  Removes the collecting handler and restores the console handler's level.
  """
  @spec uninstall(console_token()) :: :ok
  def uninstall(token) do
    restore_console(token)
    _ = :logger.remove_handler(@handler_id)
    :ok
  end

  @doc """
  Collects everything one leg produced, in order.

  Returns as soon as the stream goes quiet. An empty list means the leg
  logged nothing and ran no reporting action — a fact the narrative reports
  rather than hides.
  """
  @spec drain() :: [event()]
  def drain, do: do_drain([], @first_timeout_ms)

  defp do_drain(acc, timeout) do
    receive do
      {:demo_log, level, message} ->
        do_drain([{:log, level, message} | acc], @rest_timeout_ms)

      {:deliver_reply_ran, params, context} ->
        do_drain([{:action, params, context} | acc], @rest_timeout_ms)
    after
      timeout -> Enum.reverse(acc)
    end
  end

  @doc false
  # `:logger` handler callback. Runs synchronously in the logging process.
  # Never logs anything itself — a handler that logs re-enters itself.
  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(%{level: level, msg: msg, meta: meta}, %{config: %{collector: pid, modules: modules}}) do
    if emitting_module(meta) in modules do
      send(pid, {:demo_log, level, to_message(msg)})
    end

    :ok
  end

  def log(_event, _config), do: :ok

  defp emitting_module(%{mfa: {module, _function, _arity}}), do: module
  defp emitting_module(_meta), do: nil

  # Elixir's Logger macros emit {:string, chardata}; the other two shapes are
  # OTP's and are rendered rather than dropped, so an unexpected event is
  # visible in the transcript instead of silently missing.
  defp to_message({:string, chardata}), do: IO.chardata_to_string(chardata)
  defp to_message({:report, report}), do: inspect(report)

  defp to_message({format, args}) when is_list(format) or is_binary(format) do
    format |> :io_lib.format(args) |> IO.chardata_to_string()
  end

  defp to_message(other), do: inspect(other)

  defp silence_console do
    case :logger.get_handler_config(:default) do
      {:ok, %{level: level}} ->
        _ = :logger.update_handler_config(:default, :level, :none)
        {:console, level}

      _ ->
        :no_console
    end
  end

  defp restore_console({:console, level}) do
    _ = :logger.update_handler_config(:default, :level, level)
    :ok
  end

  defp restore_console(:no_console), do: :ok
end
