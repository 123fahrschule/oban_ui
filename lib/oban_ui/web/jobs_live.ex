defmodule ObanUI.Web.JobsLive do
  @moduledoc """
  Jobs list + detail drawer.

  ## URL state

  All filters and the sort directive are reflected in the query string so the
  page can be deep-linked and refreshed:

      ?state=available,executing&queue=default,media&worker=My.Worker
      &tags=billing,urgent&priority=0,1&q=args.user_id:42
      &from=2025-01-01T00:00:00Z&to=2025-01-02T00:00:00Z
      &sort=worker:asc

  Each "csv" parameter is split on commas and trimmed.

  ## Live updates

  Subscribes to `oban_ui:jobs:<instance>` and re-queries on tick, throttled
  to one reload per ~200ms. Active bulk operations also subscribe to
  `oban_ui:bulk:<ref>` for progress updates.
  """

  use Phoenix.LiveView, layout: false

  import ObanUI.Web.Components.Core
  import ObanUI.Web.Components.Layout, only: [shell: 1]

  alias ObanUI.Diagnostics
  alias ObanUI.Jobs.Bulk
  alias ObanUI.Jobs.Edit
  alias ObanUI.Notifier
  alias ObanUI.Queries.Jobs, as: JobsQuery
  alias ObanUI.Queries.Suggestions
  alias ObanUI.Web.Components.{Combobox, EmptyState, Timeline}
  alias ObanUI.Web.JobsLive.FilterParser
  alias Phoenix.LiveView.JS

  @page_size 25

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok =
        Phoenix.PubSub.subscribe(pubsub(), Notifier.topic({:jobs, socket.assigns.active_oban}))
    end

    socket =
      socket
      |> assign(:page_title, "Jobs")
      |> assign(:counts, %{})
      |> assign(:filters, %{})
      |> assign(:sort, nil)
      |> assign(:next_cursor, nil)
      |> assign(:job_count, 0)
      |> assign(:visible_ids, [])
      |> assign(:total_matches, 0)
      |> assign(:filter_counts, %{})
      # When the user clicks "load more" we keep appending to the stream
      # instead of resetting on every tick. We track that mode here so the
      # live-refresh handler knows to back off.
      |> assign(:loaded_pages, 1)
      |> assign(:selected_job, nil)
      |> assign(:selected_ids, MapSet.new())
      |> assign(:bulk_state, nil)
      |> assign(:edit_form, nil)
      |> assign(:expand_args, false)
      |> assign(:suggestions, %{worker: [], queue: [], tags: [], nodes: []})
      |> stream(:jobs, [])

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:filters, FilterParser.build(params))
      |> assign(:sort, FilterParser.sort(params["sort"]))
      |> load_jobs()
      |> maybe_load_detail(params)

    {:noreply, socket}
  end

  # ----- loading -----

  defp load_jobs(socket) do
    {jobs, %{next_cursor: next}} =
      JobsQuery.list(socket.assigns.filters,
        page_size: @page_size,
        sort: socket.assigns.sort || JobsQuery.default_sort(socket.assigns.filters)
      )

    counts =
      try do
        JobsQuery.count_by_state(socket.assigns.filters)
      rescue
        _ -> %{}
      end

    # count_by_state intentionally drops the state filter so the state-tab
    # counts reflect "what's available regardless of which tab is active".
    # The visible-match count, however, has to respect ALL filters, so a
    # second short COUNT(*) query is the honest answer.
    total =
      try do
        JobsQuery.count(socket.assigns.filters)
      rescue
        _ -> length(jobs)
      end

    # Per-filter counts: for each populated filter run a separate COUNT(*)
    # with ONLY that filter. Gives the operator a hint about how restrictive
    # each active condition is on its own. Caps at the populated set so we
    # never run more than however-many-filters-the-user-set queries.
    filter_counts = compute_filter_counts(socket.assigns.filters)

    socket
    |> stream(:jobs, jobs, reset: true)
    |> assign(:counts, counts)
    |> assign(:next_cursor, next)
    |> assign(:job_count, length(jobs))
    |> assign(:visible_ids, Enum.map(jobs, & &1.id))
    |> assign(:total_matches, total)
    |> assign(:filter_counts, filter_counts)
    |> assign(:loaded_pages, 1)
  end

  defp compute_filter_counts(filters) do
    filters
    |> Enum.reject(fn {_k, v} -> v in [nil, "", []] end)
    |> Enum.map(fn {k, _v} ->
      single = Map.take(filters, [k])

      count =
        try do
          JobsQuery.count(single)
        rescue
          _ -> nil
        end

      {k, count}
    end)
    |> Map.new()
  end

  # Appends the next cursor page to the existing stream. Called from the
  # "load_more" handler; never from auto-refresh.
  defp append_page(socket) do
    case socket.assigns.next_cursor do
      nil ->
        socket

      cursor ->
        {jobs, %{next_cursor: next}} =
          JobsQuery.list(socket.assigns.filters,
            page_size: @page_size,
            sort: socket.assigns.sort || JobsQuery.default_sort(socket.assigns.filters),
            cursor: cursor
          )

        socket
        |> stream(:jobs, jobs, at: -1)
        |> assign(:next_cursor, next)
        |> assign(:job_count, socket.assigns.job_count + length(jobs))
        |> assign(:visible_ids, socket.assigns.visible_ids ++ Enum.map(jobs, & &1.id))
        |> assign(:loaded_pages, socket.assigns.loaded_pages + 1)
    end
  end

  defp maybe_load_detail(%{assigns: %{live_action: :show}} = socket, %{"id" => id}) do
    case Integer.parse(id) do
      {int_id, ""} ->
        job = JobsQuery.get(int_id)

        diag =
          if job && job.state == "executing",
            do: Diagnostics.for_job(socket.assigns.active_oban, job)

        socket
        |> assign(:selected_job, job)
        |> assign(:diagnostics, diag)
        |> assign(:expand_args, false)

      _ ->
        socket
        |> assign(:selected_job, nil)
        |> assign(:diagnostics, nil)
        |> assign(:expand_args, false)
    end
  end

  defp maybe_load_detail(socket, _params) do
    socket
    |> assign(:selected_job, nil)
    |> assign(:edit_form, nil)
    |> assign(:diagnostics, nil)
    |> assign(:expand_args, false)
  end

  # ----- live messages -----

  @impl Phoenix.LiveView
  def handle_info({:tick, _buffer}, socket) do
    cond do
      socket.assigns[:reload_pending] ->
        {:noreply, socket}

      socket.assigns.loaded_pages > 1 ->
        # User is browsing older history via "Load more"; an auto-refresh
        # would yank them back to page 1. Skip the tick.
        {:noreply, socket}

      true ->
        Process.send_after(self(), :reload_now, 200)
        {:noreply, assign(socket, :reload_pending, true)}
    end
  end

  def handle_info(:reload_now, socket) do
    {:noreply, socket |> assign(:reload_pending, false) |> load_jobs()}
  end

  def handle_info({:bulk_progress, %{ref: ref} = msg}, socket) do
    case socket.assigns.bulk_state do
      %{ref: ^ref} = state -> {:noreply, assign(socket, :bulk_state, Map.merge(state, msg))}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:bulk_completed, %{ref: ref} = msg}, socket) do
    case socket.assigns.bulk_state do
      %{ref: ^ref} ->
        Phoenix.PubSub.unsubscribe(pubsub(), "oban_ui:bulk:#{ref}")

        {:noreply,
         socket
         |> assign(:bulk_state, Map.merge(%{state: :completed}, msg))
         |> load_jobs()
         |> put_flash(:info, "Bulk action finished (#{msg.done}/#{msg.total})")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # ----- events: filters / sort / nav -----

  @impl Phoenix.LiveView
  def handle_event("filter", params, socket) do
    # The state-tabs and sort buttons live outside the form, so a plain
    # phx-change firing would wipe them out of the URL. Merge the form-only
    # fields back into the existing filter state to preserve them.
    query =
      socket
      |> build_query_from_filters()
      |> Map.merge(build_query(params))
      |> drop_empty()

    # Refresh suggestions for the text fields that triggered the change.
    # phx-change carries the entire form payload, including a "_target" key
    # naming the input that fired the event — only that field's dropdown
    # should pop, so we don't clutter the page with three more.
    target = List.last(params["_target"] || [])
    suggestions = recompute_suggestions(socket.assigns.suggestions, target, params)

    {:noreply,
     socket
     |> assign(:suggestions, suggestions)
     |> push_patch(to: jobs_path(socket, query))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: jobs_path(socket, %{}))}
  end

  def handle_event("toggle_state", %{"state" => state}, socket) do
    current = socket.assigns.filters[:states] || []

    next_states =
      if state in current, do: List.delete(current, state), else: [state | current]

    query =
      socket
      |> build_query_from_filters()
      |> Map.put("state", Enum.join(next_states, ","))

    {:noreply, push_patch(socket, to: jobs_path(socket, query))}
  end

  def handle_event("sort", %{"field" => field}, socket) do
    # Same field-validation as in FilterParser — only known sortable fields.
    field_atom =
      Enum.find(JobsQuery.sortable_fields(), &(Atom.to_string(&1) == field))

    sort =
      case {field_atom, socket.assigns.sort} do
        {nil, _} -> nil
        {f, {f, :asc}} -> {f, :desc}
        {f, {f, :desc}} -> nil
        {f, _} -> {f, :asc}
      end

    query =
      socket
      |> build_query_from_filters()
      |> put_sort_query(sort)

    {:noreply, push_patch(socket, to: jobs_path(socket, query))}
  end

  def handle_event("combobox_pick", %{"field" => field, "pick" => value}, socket) do
    # Replace the matching filter with the picked value, clear the suggestion
    # list for that field so the dropdown closes, and patch the URL so the
    # query reloads. See Combobox docs for why the attribute is "pick",
    # not "value".
    query =
      socket
      |> build_query_from_filters()
      |> Map.put(field, value)
      |> drop_empty()

    suggestions =
      Map.put(socket.assigns.suggestions, suggestion_key(field), [])

    {:noreply,
     socket
     |> assign(:suggestions, suggestions)
     |> push_patch(to: jobs_path(socket, query))}
  end

  # ----- events: single-job actions -----

  def handle_event("retry", %{"id" => id}, socket), do: handle_action(socket, :retry, id)
  def handle_event("cancel", %{"id" => id}, socket), do: handle_action(socket, :cancel, id)
  def handle_event("delete", %{"id" => id}, socket), do: handle_action(socket, :delete, id)

  def handle_event("expand_args", _params, socket) do
    {:noreply, assign(socket, :expand_args, true)}
  end

  def handle_event("collapse_args", _params, socket) do
    {:noreply, assign(socket, :expand_args, false)}
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, push_patch(socket, to: jobs_path(socket, build_query_from_filters(socket)))}
  end

  # ----- events: selection + bulk -----

  def handle_event("toggle_select", %{"id" => id}, socket) do
    id_int = String.to_integer(id)
    set = socket.assigns.selected_ids

    next =
      if MapSet.member?(set, id_int),
        do: MapSet.delete(set, id_int),
        else: MapSet.put(set, id_int)

    {:noreply, assign(socket, :selected_ids, next)}
  end

  def handle_event("load_more", _params, socket) do
    {:noreply, append_page(socket)}
  end

  def handle_event("toggle_select_all", _params, socket) do
    visible = socket.assigns.visible_ids
    selected = socket.assigns.selected_ids

    all_visible_selected? =
      visible != [] and Enum.all?(visible, &MapSet.member?(selected, &1))

    next =
      if all_visible_selected? do
        Enum.reduce(visible, selected, &MapSet.delete(&2, &1))
      else
        Enum.reduce(visible, selected, &MapSet.put(&2, &1))
      end

    {:noreply, assign(socket, :selected_ids, next)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected_ids, MapSet.new())}
  end

  def handle_event("bulk_preview", %{"action" => action}, socket) do
    scope = bulk_scope(socket)
    preview = Bulk.preview(scope.filters)
    count = Bulk.count(scope.filters)

    {:noreply,
     assign(socket, :bulk_state, %{
       state: :preview,
       action: action,
       scope: scope.kind,
       count: count,
       preview: preview,
       filters: scope.filters
     })}
  end

  def handle_event("bulk_cancel", _params, socket) do
    {:noreply, assign(socket, :bulk_state, nil)}
  end

  def handle_event("bulk_confirm", _params, socket) do
    case socket.assigns.bulk_state do
      %{state: :preview, action: action, filters: filters} ->
        actor = %{access: socket.assigns.access, user: socket.assigns.current_user}
        action_atom = String.to_existing_atom(action)

        case Bulk.run(actor, action_atom, filters, oban_name: socket.assigns.active_oban) do
          {:ok, :sync, affected} ->
            {:noreply,
             socket
             |> assign(:bulk_state, nil)
             |> assign(:selected_ids, MapSet.new())
             |> load_jobs()
             |> put_flash(:info, "#{action_atom}: #{affected} jobs affected")}

          {:ok, :async, ref, estimate} ->
            :ok = Phoenix.PubSub.subscribe(pubsub(), "oban_ui:bulk:#{ref}")

            {:noreply,
             assign(socket, :bulk_state, %{
               state: :running,
               action: action,
               ref: ref,
               total: estimate,
               done: 0
             })}

          {:error, :forbidden} ->
            {:noreply, socket |> assign(:bulk_state, nil) |> put_flash(:error, "Not permitted")}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:bulk_state, nil)
             |> put_flash(:error, "Bulk failed: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # ----- events: edit -----

  def handle_event("edit_start", _params, socket) do
    case socket.assigns.selected_job do
      nil ->
        {:noreply, socket}

      %Oban.Job{} = job ->
        form = %{
          "priority" => job.priority,
          "tags" => Enum.join(job.tags || [], ", "),
          "max_attempts" => job.max_attempts,
          "scheduled_at" => format_dt_input(job.scheduled_at),
          "errors" => %{}
        }

        {:noreply, assign(socket, :edit_form, form)}
    end
  end

  def handle_event("edit_change", %{"job" => attrs}, socket) do
    {:noreply, assign(socket, :edit_form, Map.merge(socket.assigns.edit_form || %{}, attrs))}
  end

  def handle_event("edit_cancel", _params, socket) do
    {:noreply, assign(socket, :edit_form, nil)}
  end

  def handle_event("edit_save", %{"job" => attrs}, socket) do
    case socket.assigns.selected_job do
      nil ->
        {:noreply, socket}

      %Oban.Job{} = job ->
        actor = %{access: socket.assigns.access, user: socket.assigns.current_user}

        case Edit.update(actor, job, attrs, socket.assigns.active_oban) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(:selected_job, updated)
             |> assign(:edit_form, nil)
             |> load_jobs()
             |> put_flash(:info, "Job #{updated.id} updated")}

          {:error, :forbidden} ->
            {:noreply, put_flash(socket, :error, "Not permitted")}

          {:error, {:not_editable_state, state}} ->
            {:noreply, put_flash(socket, :error, "Cannot edit in state #{state}")}

          {:error, errors} ->
            errors_map = Map.new(errors, fn {k, {msg, _}} -> {k, msg} end)
            {:noreply, assign(socket, :edit_form, Map.put(attrs, "errors", errors_map))}
        end
    end
  end

  # ----- events: instance switch -----

  def handle_event("switch_instance", %{"value" => name}, socket) do
    case Enum.find(socket.assigns.oban_names, &(to_string(&1) == name)) do
      nil -> {:noreply, socket}
      atom -> {:noreply, push_navigate(socket, to: "#{socket.assigns.base_path}/i/#{atom}/jobs")}
    end
  end

  # ----- helpers -----

  defp handle_action(socket, action, id_str) do
    actor = %{access: socket.assigns.access, user: socket.assigns.current_user}
    id = String.to_integer(id_str)

    fun =
      case action do
        :retry -> &ObanUI.Jobs.retry/3
        :cancel -> &ObanUI.Jobs.cancel/3
        :delete -> &ObanUI.Jobs.delete/3
      end

    case fun.(actor, id, socket.assigns.active_oban) do
      {:ok, _result} -> {:noreply, load_jobs(socket) |> put_flash(:info, "#{action} ok")}
      {:error, :forbidden} -> {:noreply, put_flash(socket, :error, "Not permitted")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  defp bulk_scope(socket) do
    selected = socket.assigns.selected_ids

    if MapSet.size(selected) > 0 do
      %{kind: :selection, filters: %{ids: MapSet.to_list(selected)}}
    else
      %{kind: :filters, filters: socket.assigns.filters}
    end
  end

  defp build_query(params) do
    params
    |> Map.take(~w(state queue worker tags node priority q from to))
    |> Map.new()
  end

  defp drop_empty(map),
    do: Enum.reject(map, fn {_k, v} -> v in [nil, "", []] end) |> Map.new()

  defp build_query_from_filters(socket) do
    Enum.into(socket.assigns.filters, %{}, fn
      {:states, list} -> {"state", Enum.join(list, ",")}
      {:queues, list} -> {"queue", Enum.join(list, ",")}
      {:workers, list} -> {"worker", Enum.join(list, ",")}
      {:tags, list} -> {"tags", Enum.join(list, ",")}
      {:nodes, list} -> {"node", Enum.join(list, ",")}
      {:priorities, list} -> {"priority", Enum.join(list, ",")}
      {:search, value} -> {"q", value}
      {:inserted_after, dt} -> {"from", DateTime.to_iso8601(dt)}
      {:inserted_before, dt} -> {"to", DateTime.to_iso8601(dt)}
      _ -> {"", ""}
    end)
    |> Map.reject(fn {k, _} -> k == "" end)
    |> put_sort_query(socket.assigns.sort)
  end

  defp put_sort_query(query, nil), do: Map.delete(query, "sort")

  defp put_sort_query(query, {field, dir}),
    do: Map.put(query, "sort", "#{field}:#{dir}")

  defp jobs_path(socket, query) do
    base = socket.assigns.base_path

    instance_prefix =
      if length(socket.assigns.oban_names) > 1,
        do: "/i/#{socket.assigns.active_oban}",
        else: ""

    path = base <> instance_prefix <> "/jobs"
    if map_size(query) == 0, do: path, else: path <> "?" <> URI.encode_query(query)
  end

  defp detail_path(_socket, base, oban_names, active_oban, id) do
    prefix = if length(oban_names) > 1, do: "/i/#{active_oban}", else: ""
    "#{base}#{prefix}/jobs/#{id}"
  end

  defp pubsub, do: ObanUI.Config.fetch!().pubsub

  # Returns :none, :some or :all depending on how many of the currently
  # rendered rows are in the user's selection set. The render layer
  # uses this to drive the checkbox's `data-state` and the JS hook
  # turns `data-state="some"` into `el.indeterminate = true`.
  defp select_all_state(visible, selected) do
    cond do
      visible == [] -> :none
      Enum.all?(visible, &MapSet.member?(selected, &1)) -> :all
      Enum.any?(visible, &MapSet.member?(selected, &1)) -> :some
      true -> :none
    end
  end

  defp suggestion_key("worker"), do: :worker
  defp suggestion_key("queue"), do: :queue
  defp suggestion_key("tags"), do: :tags
  defp suggestion_key("node"), do: :nodes
  defp suggestion_key(_), do: :__unknown__

  # Only one combobox at a time should be open. We rebuild the suggestions
  # map clearing every field except the one that fired the change — and even
  # for that one we only query if the user has typed something. An empty
  # value collapses the dropdown.
  defp recompute_suggestions(_old, target, params)
       when target in ~w(worker queue tags node) do
    typed = params[target] || ""
    key = suggestion_key(target)

    values =
      cond do
        typed == "" -> []
        key == :worker -> Suggestions.workers(typed)
        key == :queue -> Suggestions.queues(typed)
        key == :tags -> Suggestions.tags(typed)
        key == :nodes -> Suggestions.nodes(typed)
        true -> []
      end

    %{worker: [], queue: [], tags: [], nodes: []}
    |> Map.put(key, values)
  end

  defp recompute_suggestions(_old, _other_target, _params),
    do: %{worker: [], queue: [], tags: [], nodes: []}

  # 60-char single-line truncation of the args payload after running it through
  # the host resolver's format_job_args/1. Strings are shown verbatim (after
  # newline collapsing), everything else via inspect/2.
  defp preview_args(args, resolver) do
    rendered = ObanUI.Resolver.format_args(resolver, args)

    text =
      case rendered do
        binary when is_binary(binary) -> binary
        other -> inspect(other, limit: 5, printable_limit: 80)
      end

    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(80)
  end

  defp truncate(s, n) when byte_size(s) <= n, do: s
  defp truncate(s, n), do: binary_part(s, 0, n) <> "…"

  defp format_dt_input(nil), do: ""

  defp format_dt_input(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/\+.*$/, "")
    |> String.slice(0, 16)
  end

  defp format_dt_input(%NaiveDateTime{} = ndt),
    do:
      ndt |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601() |> String.slice(0, 16)

  # ----- render -----

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.shell
      base_path={@base_path}
      active={:jobs}
      oban_names={@oban_names}
      active_oban={@active_oban}
      user_display={@user_display}
    >
      <.page_header title="Jobs">
        <:actions>
          <.button can?={true} phx-click="clear_filters">Clear filters</.button>
        </:actions>
      </.page_header>

      <.flash_bar flash={@flash} />

      <.state_tabs counts={@counts} active={@filters[:states] || []} />

      <form
        phx-change="filter"
        phx-submit="filter"
        class="grid grid-cols-1 sm:grid-cols-3 lg:grid-cols-6 gap-2 mb-4"
      >
        <.filter_cell count={@filter_counts[:workers]}>
          <Combobox.render
            field="worker"
            value={join_list(@filters[:workers])}
            placeholder="worker"
            suggestions={@suggestions.worker}
          />
        </.filter_cell>
        <.filter_cell count={@filter_counts[:queues]}>
          <Combobox.render
            field="queue"
            value={join_list(@filters[:queues])}
            placeholder="queue"
            suggestions={@suggestions.queue}
          />
        </.filter_cell>
        <.filter_cell count={@filter_counts[:tags]}>
          <Combobox.render
            field="tags"
            value={join_list(@filters[:tags])}
            placeholder="tags (comma)"
            suggestions={@suggestions.tags}
          />
        </.filter_cell>
        <.filter_cell count={@filter_counts[:nodes]}>
          <Combobox.render
            field="node"
            value={join_list(@filters[:nodes])}
            placeholder="node"
            suggestions={@suggestions.nodes}
          />
        </.filter_cell>
        <.filter_cell count={@filter_counts[:priorities]}>
          <input
            name="priority"
            class="oban-ui-input"
            placeholder="priority (0-9)"
            value={join_list(@filters[:priorities])}
            phx-debounce="300"
          />
        </.filter_cell>
        <.filter_cell count={@filter_counts[:search]}>
          <input
            name="q"
            class="oban-ui-input"
            placeholder="search args.path:value"
            value={@filters[:search]}
            phx-debounce="400"
          />
        </.filter_cell>
        <label class="text-xs text-slate-500 sm:col-span-1 flex items-center gap-1">
          <span>from</span>
          <input
            name="from"
            type="datetime-local"
            class="oban-ui-input text-xs py-1"
            value={format_dt_input(@filters[:inserted_after])}
          />
        </label>
        <label class="text-xs text-slate-500 sm:col-span-1 flex items-center gap-1">
          <span>to</span>
          <input
            name="to"
            type="datetime-local"
            class="oban-ui-input text-xs py-1"
            value={format_dt_input(@filters[:inserted_before])}
          />
        </label>
      </form>

      <p class="text-xs text-slate-500 mb-2">
        Showing <strong>{@job_count}</strong>
        <span :if={@total_matches > @job_count}>of {@total_matches}</span>
        matching job<span :if={@total_matches != 1}>s</span>
        <span :if={filters_present?(@filters)} class="text-slate-400">· filtered</span>
      </p>

      <.bulk_bar
        :if={MapSet.size(@selected_ids) > 0 or filters_present?(@filters)}
        selected={MapSet.size(@selected_ids)}
        access={@access}
      />

      <.bulk_panel :if={@bulk_state} state={@bulk_state} />

      <EmptyState.render :if={@job_count == 0} title="No jobs match the current filters." class="mb-4">
        <p :if={filters_present?(@filters)}>
          Try
          <button type="button" phx-click="clear_filters" class="underline">clearing filters</button>
          to see all jobs.
        </p>
        <p :if={not filters_present?(@filters)}>
          Once your app inserts jobs they will appear here within a second.
        </p>
      </EmptyState.render>

      <table :if={@job_count > 0} class="oban-ui-table" role="table" aria-label="Jobs">
        <caption class="sr-only">List of Oban jobs matching the current filters</caption>
        <thead>
          <tr>
            <th class="w-6" scope="col">
              <input
                type="checkbox"
                id="oban-ui-select-all"
                phx-hook="Indeterminate"
                phx-click="toggle_select_all"
                checked={select_all_state(@visible_ids, @selected_ids) == :all}
                data-state={Atom.to_string(select_all_state(@visible_ids, @selected_ids))}
                aria-label={"Toggle selection for #{length(@visible_ids)} visible jobs"}
              />
            </th>
            <.sort_th field={:id} label="ID" sort={@sort} />
            <.sort_th field={:state} label="State" sort={@sort} />
            <.sort_th field={:queue} label="Queue" sort={@sort} />
            <.sort_th field={:worker} label="Worker" sort={@sort} />
            <th scope="col">Args</th>
            <.sort_th field={:priority} label="Prio" sort={@sort} />
            <th scope="col">Attempt</th>
            <.sort_th field={:inserted_at} label="Inserted" sort={@sort} />
            <th class="text-right" scope="col">Actions</th>
          </tr>
        </thead>
        <tbody id="jobs" phx-update="stream">
          <tr
            :for={{dom_id, job} <- @streams.jobs}
            id={dom_id}
            phx-click={JS.patch(detail_path(@socket, @base_path, @oban_names, @active_oban, job.id))}
            class="cursor-pointer hover:bg-slate-50"
          >
            <td onclick="event.stopPropagation()">
              <input
                type="checkbox"
                phx-click="toggle_select"
                phx-value-id={job.id}
                checked={MapSet.member?(@selected_ids, job.id)}
                aria-label={"Select job " <> Integer.to_string(job.id)}
              />
            </td>
            <td class="font-mono">{job.id}</td>
            <td><.state_badge state={job.state} /></td>
            <td>{job.queue}</td>
            <td class="font-mono text-xs">{job.worker}</td>
            <td class="font-mono text-xs text-slate-600 max-w-xs">
              <span class="block truncate" title={preview_args(job.args, @resolver)}>
                {preview_args(job.args, @resolver)}
              </span>
            </td>
            <td>{job.priority}</td>
            <td>{job.attempt}/{job.max_attempts}</td>
            <td><.relative_time datetime={job.inserted_at} /></td>
            <td class="text-right" onclick="event.stopPropagation()">
              <.kebab_menu id={"actions-#{job.id}"} label={"Actions for job #{job.id}"}>
                <.menu_item
                  can?={
                    @access.retry_jobs and
                      job.state in ~w(cancelled discarded retryable scheduled completed)
                  }
                  phx-click="retry"
                  phx-value-id={job.id}
                >
                  Retry
                </.menu_item>
                <.menu_item
                  can?={
                    @access.cancel_jobs and job.state in ~w(available scheduled executing retryable)
                  }
                  phx-click="cancel"
                  phx-value-id={job.id}
                  data-confirm="Cancel this job?"
                >
                  Cancel
                </.menu_item>
                <.menu_item
                  variant="danger"
                  can?={@access.delete_jobs}
                  phx-click="delete"
                  phx-value-id={job.id}
                  data-confirm="Permanently delete this job?"
                >
                  Delete
                </.menu_item>
              </.kebab_menu>
            </td>
          </tr>
        </tbody>
      </table>

      <div :if={@job_count > 0} class="flex items-center justify-between mt-3 text-sm text-slate-500">
        <div :if={@loaded_pages > 1} class="text-amber-600">
          Live refresh paused while browsing older pages.
          <button type="button" phx-click="clear_filters" class="underline">Back to latest</button>
        </div>
        <span :if={@loaded_pages == 1}>&nbsp;</span>

        <button
          :if={@next_cursor}
          type="button"
          phx-click="load_more"
          class="oban-ui-btn-secondary"
        >
          Load more
        </button>
      </div>

      <.detail_drawer
        :if={@live_action == :show and @selected_job}
        job={@selected_job}
        resolver={@resolver}
        access={@access}
        edit_form={@edit_form}
        diagnostics={@diagnostics}
        expand_args={@expand_args}
      />
    </.shell>
    """
  end

  # ---- sub-components ----

  attr :count, :any, default: nil
  slot :inner_block, required: true

  # Tiny wrapper that renders a filter widget plus, if a count was computed
  # for it, a "(N)" badge in the bottom-right corner of the cell. The badge
  # tells the operator how restrictive that filter is on its own — useful
  # when chaining several filters and wondering which one is doing the work.
  defp filter_cell(assigns) do
    ~H"""
    <div class="relative">
      {render_slot(@inner_block)}
      <span
        :if={is_integer(@count)}
        class="absolute -top-2 right-1 text-[10px] font-mono bg-slate-200 text-slate-700 rounded-full px-1.5 py-0.5"
        title={"#{@count} jobs match this filter alone"}
      >
        {format_count(@count)}
      </span>
    </div>
    """
  end

  defp format_count(n) when n >= 1_000, do: "#{Float.round(n / 1000, 1)}k"
  defp format_count(n), do: Integer.to_string(n)

  attr :counts, :map, required: true
  attr :active, :list, required: true

  defp state_tabs(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-1 mb-3">
      <button
        :for={state <- ~w(available scheduled executing retryable completed cancelled discarded)}
        type="button"
        phx-click="toggle_state"
        phx-value-state={state}
        class={[
          "oban-ui-badge cursor-pointer transition-opacity",
          (state in @active && "ring-2 ring-oban-500") || "opacity-70 hover:opacity-100"
        ]}
        data-state={state}
      >
        {state} ({Map.get(@counts, state, 0)})
      </button>
    </div>
    """
  end

  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :sort, :any, default: nil

  defp sort_th(assigns) do
    arrow =
      case assigns.sort do
        {field, :asc} when field == assigns.field -> " ↑"
        {field, :desc} when field == assigns.field -> " ↓"
        _ -> ""
      end

    assigns = assign(assigns, :arrow, arrow)

    ~H"""
    <th>
      <button
        type="button"
        phx-click="sort"
        phx-value-field={@field}
        class="hover:underline"
      >
        {@label}{@arrow}
      </button>
    </th>
    """
  end

  attr :selected, :integer, required: true
  attr :access, :map, required: true

  defp bulk_bar(assigns) do
    ~H"""
    <div class="flex items-center justify-between rounded-md bg-amber-50 text-amber-900 px-3 py-2 mb-3 text-sm">
      <span :if={@selected > 0}>{@selected} selected</span>
      <span :if={@selected == 0}>Bulk action will apply to <strong>all filtered jobs</strong>.</span>

      <div class="flex gap-2">
        <.button
          variant="secondary"
          can?={@access.retry_jobs}
          phx-click="bulk_preview"
          phx-value-action="retry"
        >
          Retry…
        </.button>
        <.button
          variant="secondary"
          can?={@access.cancel_jobs}
          phx-click="bulk_preview"
          phx-value-action="cancel"
        >
          Cancel…
        </.button>
        <.button
          variant="danger"
          can?={@access.delete_jobs}
          phx-click="bulk_preview"
          phx-value-action="delete"
        >
          Delete…
        </.button>
        <.button
          :if={@selected > 0}
          variant="secondary"
          can?={true}
          phx-click="clear_selection"
        >
          Clear
        </.button>
      </div>
    </div>
    """
  end

  attr :state, :map, required: true

  defp bulk_panel(assigns) do
    ~H"""
    <div class="oban-ui-card mb-3 border-amber-300">
      <div :if={@state.state == :preview}>
        <p class="font-medium mb-2">
          Confirm bulk {@state.action} — {@state.count} jobs ({@state.scope})
        </p>

        <ul class="text-xs text-slate-500 mb-3 grid grid-cols-2 sm:grid-cols-4 gap-1">
          <li :for={{state, count} <- @state.preview} :if={count > 0}>
            <span class="oban-ui-badge" data-state={state}>{state}</span>
            <span class="ml-1">{count}</span>
          </li>
        </ul>

        <div class="flex gap-2">
          <.button variant="danger" can?={true} phx-click="bulk_confirm">
            Yes, {@state.action} {@state.count} jobs
          </.button>
          <.button variant="secondary" can?={true} phx-click="bulk_cancel">Cancel</.button>
        </div>
      </div>

      <div :if={@state.state == :running}>
        <p class="font-medium mb-2">
          Running bulk {@state.action} — {@state.done}/{@state.total}
        </p>
        <div class="w-full bg-slate-200 rounded-full h-2">
          <div
            class="bg-oban-500 h-2 rounded-full"
            style={"width: #{progress_pct(@state)}%"}
          >
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp progress_pct(%{done: d, total: t}) when is_integer(t) and t > 0,
    do: trunc(d / t * 100)

  defp progress_pct(_), do: 0

  defp filters_present?(filters), do: filters != %{}

  defp flash_bar(assigns) do
    ~H"""
    <div aria-live="polite" aria-atomic="true">
      <div
        :if={Phoenix.Flash.get(@flash, :error)}
        role="alert"
        class="rounded-md bg-red-50 text-red-800 px-3 py-2 mb-3"
      >
        {Phoenix.Flash.get(@flash, :error)}
      </div>
      <div
        :if={Phoenix.Flash.get(@flash, :info)}
        role="status"
        class="rounded-md bg-emerald-50 text-emerald-800 px-3 py-2 mb-3"
      >
        {Phoenix.Flash.get(@flash, :info)}
      </div>
    </div>
    """
  end

  defp join_list(nil), do: ""
  defp join_list(list) when is_list(list), do: Enum.join(list, ",")

  # ---- detail drawer ----

  attr :job, :map, required: true
  attr :resolver, :atom, required: true
  attr :access, :map, required: true
  attr :edit_form, :any, default: nil
  attr :diagnostics, :any, default: nil
  attr :expand_args, :boolean, default: false

  # Truncate args/meta preview at this byte count. Anything larger gets
  # rendered as a head excerpt + a "Show full" toggle that reveals the
  # rest on demand. Multi-MB args are normal in some hosts (compressed
  # blobs, recorded payloads, ...) and slamming the entire string into
  # the LV diff blocks the page on every drawer open.
  @args_preview_bytes 2_000

  defp detail_drawer(assigns) do
    formatted_args = ObanUI.Resolver.format_args(assigns.resolver, assigns.job.args)
    formatted_meta = ObanUI.Resolver.format_meta(assigns.resolver, assigns.job.meta)

    editable? = assigns.job.state in Edit.editable_states()

    {args_to_render, args_truncated?, args_byte_size} =
      args_view(formatted_args, assigns.expand_args)

    assigns =
      assigns
      |> assign(:formatted_args, args_to_render)
      |> assign(:args_truncated?, args_truncated?)
      |> assign(:args_byte_size, args_byte_size)
      |> assign(:formatted_meta, formatted_meta)
      |> assign(:editable?, editable?)

    ~H"""
    <aside
      class="oban-ui-drawer p-5"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"job-detail-title-" <> Integer.to_string(@job.id)}
      id={"job-detail-drawer-" <> Integer.to_string(@job.id)}
      phx-hook="DrawerFocusTrap"
      tabindex="-1"
    >
      <div class="flex items-start justify-between mb-3">
        <div>
          <p class="text-xs text-slate-500">Job #{@job.id}</p>
          <h2
            id={"job-detail-title-" <> Integer.to_string(@job.id)}
            class="text-lg font-semibold"
          >
            {@job.worker}
          </h2>
          <p class="text-xs text-slate-500">
            <.state_badge state={@job.state} />
            · {@job.queue} · attempt {@job.attempt}/{@job.max_attempts}
          </p>
        </div>
        <button
          type="button"
          class="oban-ui-btn-secondary"
          phx-click="close_detail"
          aria-label="Close detail"
        >
          ×
        </button>
      </div>

      <section class="mb-4">
        <h3 class="text-sm font-medium mb-1">Timeline</h3>
        <Timeline.render job={@job} />
      </section>

      <section :if={@diagnostics} class="mb-4">
        <h3 class="text-sm font-medium mb-1">
          Live diagnostics <span class="text-xs text-slate-500 font-normal">(at open)</span>
        </h3>
        <.diagnostics_panel info={@diagnostics} />
      </section>

      <%= if @edit_form do %>
        <.edit_form job={@job} form={@edit_form} />
      <% else %>
        <section class="mb-4">
          <h3 class="text-sm font-medium mb-1">
            Args
            <span
              class="ml-1 text-xs text-slate-500"
              title="Edit disabled — host serialises args; see resolver.format_job_args/1"
            >
              (read-only)
            </span>
            <span :if={@args_truncated?} class="ml-1 text-xs text-amber-700">
              · truncated, full size {format_bytes(@args_byte_size)}
            </span>
          </h3>
          <.pre content={@formatted_args} />
          <button
            :if={@args_truncated? and not @expand_args}
            type="button"
            phx-click="expand_args"
            class="oban-ui-btn-secondary mt-1 text-xs"
          >
            Show full args
          </button>
          <button
            :if={@expand_args}
            type="button"
            phx-click="collapse_args"
            class="oban-ui-btn-secondary mt-1 text-xs"
          >
            Collapse
          </button>
        </section>

        <section :if={@formatted_meta not in [nil, %{}, %{"_" => nil}]} class="mb-4">
          <h3 class="text-sm font-medium mb-1">Meta</h3>
          <.pre content={@formatted_meta} />
        </section>

        <section :if={@job.errors not in [nil, []]} class="mb-4">
          <h3 class="text-sm font-medium mb-1">Errors</h3>
          <div :for={{error, idx} <- Enum.with_index(@job.errors)} class="mb-2">
            <p class="text-xs text-slate-500">
              Attempt {idx + 1} · {Map.get(error, "at")}
            </p>
            <.pre content={Map.get(error, "error") || error} />
          </div>
        </section>

        <section class="border-t border-slate-200 pt-3 flex flex-wrap gap-2">
          <.button
            variant="primary"
            can?={@access.retry_jobs}
            phx-click="retry"
            phx-value-id={@job.id}
          >
            Retry
          </.button>
          <.button
            variant="secondary"
            can?={@access.cancel_jobs}
            phx-click="cancel"
            phx-value-id={@job.id}
            data-confirm="Cancel this job?"
          >
            Cancel
          </.button>
          <.button
            variant="danger"
            can?={@access.delete_jobs}
            phx-click="delete"
            phx-value-id={@job.id}
            data-confirm="Permanently delete this job?"
          >
            Delete
          </.button>
          <.button
            variant="secondary"
            can?={@access.edit_jobs and @editable?}
            reason={
              if @editable?, do: "Insufficient permissions", else: "Cannot edit a #{@job.state} job"
            }
            phx-click="edit_start"
          >
            Edit
          </.button>
        </section>
      <% end %>
    </aside>
    """
  end

  attr :info, :map, required: true

  defp diagnostics_panel(%{info: %{available: true}} = assigns) do
    ~H"""
    <div class="rounded-md border border-slate-200 bg-slate-50 p-3 text-xs space-y-1">
      <p class="text-slate-600">
        Node: <span class="font-mono">{@info.node}</span>
        · PID: <span class="font-mono">{inspect(@info.pid)}</span>
      </p>
      <p class="text-slate-600">
        Status: <strong>{@info.status}</strong>
        · Memory: <strong>{format_bytes(@info.memory)}</strong>
        · Msg queue: <strong>{@info.message_queue_len}</strong>
        · Reductions: <strong>{format_int(@info.reductions)}</strong>
      </p>
      <p class="text-slate-600">
        Current function: <span class="font-mono">{format_mfa(@info.current_function)}</span>
      </p>
      <details class="mt-1">
        <summary class="cursor-pointer text-slate-600">
          Stacktrace ({length(@info.current_stacktrace || [])} frames)
        </summary>
        <.pre content={format_stacktrace(@info.current_stacktrace)} />
      </details>
    </div>
    """
  end

  defp diagnostics_panel(%{info: %{available: false}} = assigns) do
    ~H"""
    <div class="rounded-md border border-amber-300 bg-amber-50 p-3 text-xs text-amber-900">
      Process not available. {@info[:reason]}
    </div>
    """
  end

  defp format_bytes(nil), do: "—"
  defp format_bytes(n) when n < 1024, do: "#{n} B"
  defp format_bytes(n) when n < 1024 * 1024, do: "#{div(n, 1024)} KB"
  defp format_bytes(n), do: "#{Float.round(n / (1024 * 1024), 2)} MB"

  # Returns {rendered_args, truncated?, byte_size_of_full_string}.
  # If `expand?` is true, hand the entire formatted args back.
  defp args_view(args, expand?) do
    text =
      case args do
        binary when is_binary(binary) -> binary
        other -> inspect(other, pretty: true, limit: :infinity, printable_limit: :infinity)
      end

    full_size = byte_size(text)

    cond do
      full_size <= @args_preview_bytes -> {text, false, full_size}
      expand? -> {text, false, full_size}
      true -> {binary_part(text, 0, @args_preview_bytes) <> "\n…", true, full_size}
    end
  end

  defp format_int(nil), do: "—"
  defp format_int(n) when is_integer(n), do: Integer.to_string(n)

  defp format_mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
  defp format_mfa(_), do: "—"

  defp format_stacktrace(nil), do: "—"
  defp format_stacktrace([]), do: "—"

  defp format_stacktrace(frames) do
    Enum.map_join(frames, "\n", fn
      {m, f, a, loc} ->
        "  #{inspect(m)}.#{f}/#{a} #{format_loc(loc)}"

      other ->
        inspect(other)
    end)
  end

  defp format_loc(loc) when is_list(loc) do
    case Keyword.get(loc, :file) do
      nil -> ""
      file -> "(#{file}:#{Keyword.get(loc, :line, "?")})"
    end
  end

  defp format_loc(_), do: ""

  attr :job, :map, required: true
  attr :form, :map, required: true

  defp edit_form(assigns) do
    ~H"""
    <form phx-submit="edit_save" phx-change="edit_change" class="space-y-3">
      <div>
        <label class="text-sm font-medium block mb-1">Priority</label>
        <input
          name="job[priority]"
          type="number"
          min="0"
          max="9"
          value={Map.get(@form, "priority")}
          class="oban-ui-input"
        />
      </div>

      <div>
        <label class="text-sm font-medium block mb-1">Tags (comma-separated)</label>
        <input
          name="job[tags]"
          value={Map.get(@form, "tags")}
          class="oban-ui-input"
        />
      </div>

      <div>
        <label class="text-sm font-medium block mb-1">Scheduled at (UTC)</label>
        <input
          name="job[scheduled_at]"
          type="datetime-local"
          value={Map.get(@form, "scheduled_at")}
          class="oban-ui-input"
        />
      </div>

      <div>
        <label class="text-sm font-medium block mb-1">Max attempts</label>
        <input
          name="job[max_attempts]"
          type="number"
          min="1"
          value={Map.get(@form, "max_attempts")}
          class="oban-ui-input"
        />
      </div>

      <ul :if={Map.get(@form, "errors", %{}) != %{}} class="text-xs text-red-700">
        <li :for={{k, msg} <- Map.get(@form, "errors", %{})}>{k}: {msg}</li>
      </ul>

      <div class="flex gap-2 border-t border-slate-200 pt-3">
        <.button variant="primary" can?={true} type="submit">Save</.button>
        <.button variant="secondary" can?={true} phx-click="edit_cancel">Cancel</.button>
      </div>
    </form>
    """
  end
end
