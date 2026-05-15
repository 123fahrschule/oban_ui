defmodule ObanUI.Web.Components.EmptyState do
  @moduledoc """
  Friendly empty-state block. Used wherever a list view has no rows so the
  page doesn't just go blank — gives the operator a hint about what to do.
  """

  use Phoenix.Component

  attr :title, :string, required: true
  attr :class, :string, default: ""
  slot :inner_block

  def render(assigns) do
    ~H"""
    <div
      role="status"
      class={[
        "border border-dashed border-slate-300 rounded-lg p-6 text-center text-sm text-slate-500",
        @class
      ]}
    >
      <p class="font-medium text-slate-700 mb-1">{@title}</p>
      <div :if={@inner_block != []}>{render_slot(@inner_block)}</div>
    </div>
    """
  end
end
