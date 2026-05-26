defmodule ObanUI.Resolver do
  @moduledoc """
  Behaviour for host apps to plug auth and display formatting into the UI.

  All callbacks are optional. The library falls back to `ObanUI.Resolver.Default`,
  which grants `:all` access and renders job args/meta as-is.

  ## Auth

  `c:resolve_user/1` extracts the current user from the connection (e.g. from
  `conn.assigns[:current_user]`). The user term is passed to `c:resolve_access/1`,
  which returns one of:

    * `:all` - full access to all actions
    * `:read_only` - all action buttons are disabled and server-side checks
      reject any action attempts
    * a keyword list of action permissions, e.g.
      `[cancel_jobs: true, retry_jobs: true, delete_jobs: false,
        pause_queues: false, scale_queues: false, insert_jobs: false]`

  Unrecognised actions default to `false` when a keyword list is returned.

  ## Display formatting

  Many apps wrap job args in encoded payloads (e.g. `:erlang.term_to_binary`
  base64) to preserve Elixir terms across the JSON boundary. `c:format_job_args/1`
  and `c:format_job_meta/1` let you decode those for human-readable display.

  ## Example

      defmodule MyAppWeb.ObanUIResolver do
        @behaviour ObanUI.Resolver

        def resolve_user(conn), do: conn.assigns[:current_user]

        def resolve_access(%{role: :admin}), do: :all
        def resolve_access(_), do: :read_only

        def format_user(%{name: name, email: email}), do: %{name: name, email: email}

        def format_job_args(%{"_term" => bin}) when is_binary(bin) do
          bin
          |> Base.decode64!()
          |> :erlang.binary_to_term([:safe])
          |> inspect(pretty: true, limit: :infinity)
        end

        def format_job_args(args), do: args
      end
  """

  @type access :: :all | :read_only | [{action(), boolean()}]
  @type action ::
          :cancel_jobs
          | :retry_jobs
          | :delete_jobs
          | :pause_queues
          | :scale_queues
          | :insert_jobs
          | :edit_jobs

  @callback resolve_user(Plug.Conn.t()) :: term() | nil
  @callback resolve_access(user :: term()) :: access()
  @callback format_user(user :: term()) :: %{name: String.t(), email: String.t() | nil}
  @callback format_job_args(args :: term()) :: term()
  @callback format_job_meta(meta :: term()) :: term()

  @optional_callbacks resolve_user: 1,
                      resolve_access: 1,
                      format_user: 1,
                      format_job_args: 1,
                      format_job_meta: 1

  @actions ~w(cancel_jobs retry_jobs delete_jobs pause_queues scale_queues insert_jobs edit_jobs)a

  @doc """
  Returns the canonical list of action atoms ObanUI checks against.
  """
  @spec actions() :: [action()]
  def actions, do: @actions

  @doc """
  Returns true if `access` grants permission for `action`.
  """
  @spec can?(access(), action()) :: boolean()
  def can?(:all, _action), do: true
  def can?(:read_only, _action), do: false

  def can?(list, action) when is_list(list) and action in @actions,
    do: Keyword.get(list, action, false)

  def can?(_, _), do: false

  @doc """
  Normalises an `access` return value into a map keyed by action atom.

  Useful for assigning a single map into LiveView socket assigns.
  """
  @spec normalize(access()) :: %{action() => boolean()}
  def normalize(:all), do: Map.new(@actions, &{&1, true})
  def normalize(:read_only), do: Map.new(@actions, &{&1, false})

  def normalize(list) when is_list(list),
    do: Map.new(@actions, fn action -> {action, Keyword.get(list, action, false)} end)

  def normalize(_), do: normalize(:read_only)

  @doc """
  Formats job args through the resolver's `c:format_job_args/1` callback,
  falling back to the raw args if the resolver doesn't implement it.

  Uses `Code.ensure_loaded?/1` before `function_exported?/3`: the latter
  returns `false` for a module that simply hasn't been loaded into memory
  yet, which would silently skip the host's formatter and leak raw
  (e.g. `__original_args`) payloads into the UI.
  """
  @spec format_args(module(), term()) :: term()
  def format_args(resolver, args) do
    if exported?(resolver, :format_job_args, 1) do
      resolver.format_job_args(args)
    else
      args
    end
  end

  @doc """
  Like `format_args/2` but for `c:format_job_meta/1`.
  """
  @spec format_meta(module(), term()) :: term()
  def format_meta(resolver, meta) do
    if exported?(resolver, :format_job_meta, 1) do
      resolver.format_job_meta(meta)
    else
      meta
    end
  end

  @doc """
  Formats the display user through `c:format_user/1`, falling back to the
  default formatter.
  """
  @spec format_user(module(), term()) :: %{name: String.t(), email: String.t() | nil}
  def format_user(resolver, user) do
    if exported?(resolver, :format_user, 1) do
      resolver.format_user(user)
    else
      __MODULE__.Default.format_user(user)
    end
  end

  @doc """
  Resolves access for `user`, defaulting to `:all` when the resolver
  doesn't implement `c:resolve_access/1`.
  """
  @spec resolve_access(module(), term()) :: access()
  def resolve_access(resolver, user) do
    if exported?(resolver, :resolve_access, 1) do
      resolver.resolve_access(user)
    else
      :all
    end
  end

  @doc false
  # function_exported?/3 reports false for an unloaded module. Forcing a
  # load first means a resolver referenced only from the router macro is
  # still found at first render.
  def exported?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end
end
