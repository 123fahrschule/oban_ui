defmodule ObanUI.DevApp.Migrator do
  @moduledoc false

  def run! do
    Ecto.Migrator.run(ObanUI.DevApp.Repo, [{0, ObanUI.DevApp.Migrations.SetupOban}], :up,
      all: true,
      log: false
    )
  end
end

defmodule ObanUI.DevApp.Migrations.SetupOban do
  use Ecto.Migration

  def up do
    Oban.Migrations.up()
  end

  def down do
    Oban.Migrations.down()
  end
end
