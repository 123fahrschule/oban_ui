defmodule ObanUI.Web.Components.Combobox do
  @moduledoc """
  Filter input with a server-rendered suggestion dropdown.

  Replaces the browser-native `<datalist>` whose default rendering varies
  across OSes and can't be styled. This component:

    * Renders an `<input>` styled like the other filter fields.
    * Wires `phx-keyup="suggest"` (debounced 200ms) so the parent LiveView
      refreshes its suggestion list as the user types.
    * Shows a positioned `<ul>` of suggestions below the input whenever
      the input is focused **and** the suggestion list is non-empty.
    * Each option fires `phx-click="combobox_pick"` with the field name
      and value, expected to set the corresponding filter on the parent.

  ## Assigns

    * `:field`     — the URL parameter name (`"worker"`, `"queue"`, …).
                     Doubles as the input's `name` attribute.
    * `:value`     — current value of the input (as a string).
    * `:placeholder` — input placeholder.
    * `:suggestions` — list of strings to show.

  ## Parent expectations

  The parent LiveView must handle:

      def handle_event("suggest", %{"value" => v, "_target" => ["worker"]}, …)
      def handle_event("combobox_pick", %{"field" => "worker", "value" => …}, …)

  See `ObanUI.Web.JobsLive` for the wiring.
  """

  use Phoenix.Component

  attr :field, :string, required: true
  attr :value, :string, default: ""
  attr :placeholder, :string, default: ""
  attr :suggestions, :list, default: []

  def render(assigns) do
    ~H"""
    <div class="oban-ui-combobox relative" data-field={@field}>
      <input
        name={@field}
        type="text"
        value={@value}
        placeholder={@placeholder}
        class="oban-ui-input"
        autocomplete="off"
        spellcheck="false"
        phx-debounce="250"
        aria-autocomplete="list"
        aria-expanded={@suggestions != [] && "true" || "false"}
        aria-controls={"combobox-list-" <> @field}
      />
      <ul
        :if={@suggestions != []}
        id={"combobox-list-" <> @field}
        role="listbox"
        class="oban-ui-combobox-list absolute z-30 mt-1 w-full max-h-56 overflow-auto rounded-md border border-slate-300 bg-white shadow-lg text-sm"
      >
        <li
          :for={s <- @suggestions}
          role="option"
          tabindex="-1"
          phx-click="combobox_pick"
          phx-value-field={@field}
          phx-value-value={s}
          class="px-3 py-1.5 cursor-pointer hover:bg-oban-50 font-mono text-xs"
        >
          {s}
        </li>
      </ul>
    </div>
    """
  end
end
