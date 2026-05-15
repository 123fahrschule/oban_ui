defmodule ObanUI.Config do
  @moduledoc """
  Runtime configuration registry for ObanUI.

  Stored in a `:persistent_term` for cheap reads from any process (LiveView,
  notifier, stats recorder). Written once at supervisor start.
  """

  defstruct oban_names: [],
            default_oban: nil,
            pubsub: nil,
            repo: nil,
            stats: %{enabled: true, persist: false},
            started_at: nil

  @type t :: %__MODULE__{
          oban_names: [atom()],
          default_oban: atom(),
          pubsub: atom(),
          repo: module() | nil,
          stats: %{enabled: boolean(), persist: boolean()},
          started_at: DateTime.t() | nil
        }

  @key {__MODULE__, :runtime}

  @doc """
  Normalises raw supervisor opts into a `t:t/0` and stores it in persistent_term.
  """
  @spec put(keyword()) :: t()
  def put(opts) do
    oban_names = opts[:oban_names] || [Oban]
    pubsub = opts[:pubsub] || raise ArgumentError, "ObanUI requires :pubsub option"
    stats_opts = Map.merge(%{enabled: true, persist: false}, Map.new(opts[:stats] || []))

    config = %__MODULE__{
      oban_names: oban_names,
      default_oban: hd(oban_names),
      pubsub: pubsub,
      repo: opts[:repo] || infer_repo(oban_names),
      stats: stats_opts,
      started_at: DateTime.utc_now()
    }

    :persistent_term.put(@key, config)
    config
  end

  @doc """
  Returns the stored config or raises if ObanUI hasn't been started.
  """
  @spec fetch!() :: t()
  def fetch! do
    case :persistent_term.get(@key, :missing) do
      :missing ->
        raise "ObanUI is not started — add `{ObanUI, ...}` to your supervision tree"

      config ->
        config
    end
  end

  @doc """
  Returns the configured repo. Tries to infer from an Oban instance if not set.
  """
  @spec repo() :: module()
  def repo do
    case fetch!().repo do
      nil ->
        raise "ObanUI could not infer the Ecto repo — pass `repo:` to the supervisor"

      repo ->
        repo
    end
  end

  @doc """
  Returns the validated Oban instance name. Raises if `name` isn't configured.
  """
  @spec oban!(atom() | nil) :: atom()
  def oban!(name \\ nil)
  def oban!(nil), do: fetch!().default_oban

  def oban!(name) do
    config = fetch!()

    if name in config.oban_names do
      name
    else
      raise ArgumentError,
            "unknown Oban instance #{inspect(name)} (configured: #{inspect(config.oban_names)})"
    end
  end

  defp infer_repo(oban_names) do
    Enum.find_value(oban_names, fn name ->
      try do
        %Oban.Config{repo: repo} = Oban.config(name)
        repo
      rescue
        _ -> nil
      end
    end)
  end
end
