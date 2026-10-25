defmodule Astral.Site do
  @moduledoc """
  A discovered Astral site ready to render.
  """

  @type entries :: %{atom() => [Astral.Entry.t()]}

  @type t :: %__MODULE__{
          config: Astral.Config.t(),
          pages: [Astral.Page.t()],
          collections: [Astral.Collection.t()],
          entries: entries(),
          routes: [Astral.Route.t()],
          mode: :build | :dev,
          asset_manifest: %{String.t() => Volt.Builder.ManifestEntry.t()} | nil
        }

  defstruct config: nil,
            pages: [],
            collections: [],
            entries: %{},
            routes: [],
            mode: :build,
            asset_manifest: nil
end
