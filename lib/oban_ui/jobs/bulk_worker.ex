defmodule ObanUI.Jobs.BulkWorker do
  @moduledoc """
  Oban worker that performs the asynchronous bulk path of
  `ObanUI.Jobs.Bulk.run/3`.

  The worker fetches all matching job IDs (without payload) up front, then
  iterates in 500-row chunks. After each chunk, it broadcasts progress to
  `"oban_ui:bulk:<ref>"`. The LiveView that initiated the request listens
  there and updates a progress bar.

  We deliberately keep this worker's args minimal — the filter is JSON-encoded
  so it survives the round-trip and is decoded back to atoms via
  `ObanUI.Jobs.Bulk.deserialise_filters/1`.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias ObanUI.Config
  alias ObanUI.Jobs.Bulk
  alias ObanUI.Queries.Jobs, as: JobsQuery

  @chunk 500

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    action = String.to_existing_atom(args["action"])
    oban_name = String.to_existing_atom(args["oban_name"])
    ref = args["ref"]
    filters = Bulk.deserialise_filters(args["filters"] || %{})

    actor = %{user: args["actor"]["user"]}

    ids = collect_ids(filters)
    total = length(ids)

    broadcast(ref, {:bulk_progress, %{done: 0, total: total, ref: ref}})

    {done, _} =
      ids
      |> Enum.chunk_every(@chunk)
      |> Enum.reduce({0, total}, fn chunk, {done, total} ->
        :ok = Bulk.perform_chunk(action, chunk, oban_name, actor)
        new_done = done + length(chunk)
        broadcast(ref, {:bulk_progress, %{done: new_done, total: total, ref: ref}})
        {new_done, total}
      end)

    broadcast(ref, {:bulk_completed, %{done: done, total: total, ref: ref}})

    :ok
  end

  defp collect_ids(filters) do
    # Must NOT use JobsQuery.list/2: it clamps page_size to 200 and would
    # silently truncate the bulk set. matching_ids/1 runs an unbounded
    # SELECT id query so we see every match.
    JobsQuery.matching_ids(filters)
  end

  defp broadcast(ref, msg) do
    pubsub = Config.fetch!().pubsub
    Phoenix.PubSub.broadcast(pubsub, "oban_ui:bulk:#{ref}", msg)
  end
end
