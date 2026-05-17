defmodule ObanUI.Router do
  @moduledoc """
  Provides the router macro used by host applications to mount the ObanUI
  dashboard.

  ## Usage

      defmodule MyAppWeb.Router do
        use MyAppWeb, :router
        import ObanUI.Router

        scope "/admin", MyAppWeb do
          pipe_through [:browser, :require_admin]

          oban_ui_dashboard "/oban",
            resolver: MyAppWeb.ObanUIResolver,
            oban_names: [Oban]
        end
      end

  ## Options

    * `:as` — route name prefix. Defaults to `:oban_ui_dashboard`.
    * `:resolver` — module implementing `ObanUI.Resolver`. Defaults to
      `ObanUI.Resolver.Default`.
    * `:oban_names` — list of Oban instance atoms. Defaults to `[Oban]`.
    * `:csp_nonce_assign_key` — atom (e.g. `:csp_nonce`) for the CSP nonce
      assigned by the host pipeline. When set, ObanUI uses the nonce on its
      inline `<style>`/`<script>` tags.

  Asset routes (`/<path>/css/:file`, `/<path>/js/:file`) are emitted as plain
  `Plug` calls and bypass the `live_session`.
  """

  @doc """
  Mounts the ObanUI dashboard at `path`.
  """
  defmacro oban_ui_dashboard(path, opts \\ []) do
    {csp_key, opts} = Keyword.pop(opts, :csp_nonce_assign_key)
    {session_name, opts} = Keyword.pop(opts, :as, :oban_ui_dashboard)

    opts =
      Keyword.merge(
        [
          resolver: ObanUI.Resolver.Default,
          oban_names: [Oban],
          sandbox: false
        ],
        opts
      )

    quote bind_quoted: [path: path, opts: opts, session_name: session_name, csp_key: csp_key] do
      scope path, alias: false, as: session_name do
        # Static assets — served from priv/static via a dedicated plug.
        get "/css/:file", ObanUI.Plug.Assets, :css
        get "/js/:file", ObanUI.Plug.Assets, :js

        live_session session_name,
          session: %{
            "oban_ui_opts" => %{
              resolver: opts[:resolver],
              oban_names: opts[:oban_names],
              csp_nonce_assign_key: csp_key,
              base_path: path,
              session_name: session_name,
              sandbox: opts[:sandbox]
            }
          },
          on_mount: [{ObanUI.Web.OnMount, :default}],
          root_layout: {ObanUI.Web.Layouts, :root} do
          live "/", ObanUI.Web.DashboardLive, :index
          live "/jobs", ObanUI.Web.JobsLive, :index
          live "/jobs/:id", ObanUI.Web.JobsLive, :show
          live "/queues", ObanUI.Web.QueuesLive, :index
          live "/queues/:name", ObanUI.Web.QueuesLive, :show
          live "/crons", ObanUI.Web.CronsLive, :index

          # Multi-instance scoped routes — same LiveViews, instance from path.
          live "/i/:instance", ObanUI.Web.DashboardLive, :index
          live "/i/:instance/jobs", ObanUI.Web.JobsLive, :index
          live "/i/:instance/jobs/:id", ObanUI.Web.JobsLive, :show
          live "/i/:instance/queues", ObanUI.Web.QueuesLive, :index
          live "/i/:instance/queues/:name", ObanUI.Web.QueuesLive, :show
          live "/i/:instance/crons", ObanUI.Web.CronsLive, :index
        end
      end
    end
  end
end
