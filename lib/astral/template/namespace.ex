defmodule Astral.Template.Namespace do
  @moduledoc """
  Maps the components and layouts directories to compiled HEEx component modules.

  Top-level files under `components/` form the root module, which templates
  import, so `components/pill.astral` is called as `<.pill>`. Each subdirectory
  becomes a module that templates alias by its first segment, so
  `components/article/code_pane.astral` is called as `<Article.code_pane>` and
  `components/docs/api/table.astral` as `<Docs.Api.table>`.

  Layouts are components in the `Layouts` module: `layouts/site.astral` is
  called as `<Layouts.site>` and `layouts/blog/post.astral` as
  `<Layouts.Blog.post>`.

  Modules are content-addressed by the whole set of sources, so they compile
  once per set and every template rendered against that set shares them.
  """

  alias Astral.Template.Source

  @extension ".astral"

  @type definition :: {atom(), Source.t()}

  @type t :: %__MODULE__{
          base: module(),
          root: [definition()],
          modules: %{module() => [definition()]},
          aliases: [module()]
        }

  defstruct base: nil, root: [], modules: %{}, aliases: []

  @doc "Discover a site's components and layouts and name their modules."
  @spec discover(Astral.Config.t()) :: {:ok, t()} | {:error, term()}
  def discover(%Astral.Config{} = config) do
    components = sources(config.components)
    layouts = sources(config.layouts)
    base = base_module(config.root, components ++ layouts)

    with :ok <- reject_eex_layouts(config.layouts),
         {:ok, grouped} <- group(components, config.components),
         :ok <- reject_layouts_directory(grouped, config.components),
         {:ok, grouped_layouts} <- group(layouts, config.layouts),
         grouped = Map.merge(grouped, prefix_layouts(grouped_layouts)),
         {:ok, aliases} <- aliases(grouped, config) do
      {root_definitions, nested} = Map.pop(grouped, [], [])

      modules =
        Map.new(nested, fn {segments, definitions} ->
          {Module.concat([base | segments]), definitions}
        end)

      {:ok,
       %__MODULE__{
         base: base,
         root: root_definitions,
         modules: modules,
         aliases: Enum.map(aliases, &Module.concat([base, &1]))
       }}
    end
  end

  @doc "Return the module holding top-level components."
  @spec root_module(t()) :: module()
  def root_module(%__MODULE__{base: base}), do: base

  @doc """
  Find the layout component for a layout name such as `"site"` or `"blog/post"`.

  A trailing `.astral` extension is ignored.
  """
  @spec layout(t(), String.t()) :: {:ok, module(), atom(), String.t()} | :error
  def layout(%__MODULE__{base: base, modules: modules}, name) when is_binary(name) do
    {dirs, [file]} =
      name |> String.trim_trailing(@extension) |> String.split("/") |> Enum.split(-1)

    module = Module.concat([base, "Layouts" | Enum.map(dirs, &Macro.camelize/1)])

    modules
    |> Map.get(module, [])
    |> Enum.find_value(:error, fn {function, %Source{path: path}} ->
      if Atom.to_string(function) == file, do: {:ok, module, function, path}
    end)
  end

  @doc """
  Reject setup-block aliases that would shadow a component module.

  `alias Blog.Site` in a template whose components include `site/` makes
  `<Site.shell>` resolve to `Blog.Site.shell/1`, so Astral fails early instead.
  """
  @spec check_setup_aliases(Macro.t(), t(), String.t()) :: :ok | {:error, term()}
  def check_setup_aliases(setup_ast, %__MODULE__{aliases: aliases}, path) do
    names = MapSet.new(aliases, &short_name/1)

    setup_ast
    |> setup_alias_names()
    |> Enum.find(&MapSet.member?(names, &1))
    |> case do
      nil -> :ok
      name -> {:error, {:component_alias_shadowed, path, name}}
    end
  end

  defp sources(dir) do
    if File.dir?(dir) do
      dir
      |> Path.join("**/*#{@extension}")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&%Source{path: &1, source: File.read!(&1)})
    else
      []
    end
  end

  defp base_module(root, sources) do
    fingerprint = {root, Enum.map(sources, &{&1.path, &1.source})}

    hash =
      :sha256
      |> :crypto.hash(:erlang.term_to_binary(fingerprint))
      |> binary_part(0, 16)
      |> Base.encode16(case: :lower)

    Module.concat([Astral.Compiled.Components, "C#{hash}"])
  end

  defp group(sources, dir) do
    entries = Enum.map(sources, &split_source(&1, dir))

    case entries |> Enum.flat_map(&elem(&1, 0)) |> Enum.find(&(not valid_segment?(&1))) do
      nil ->
        {:ok,
         Enum.group_by(
           entries,
           fn {dirs, _definition} -> Enum.map(dirs, &Macro.camelize/1) end,
           &elem(&1, 1)
         )}

      segment ->
        {:error, {:invalid_component_directory, Path.join(dir, segment)}}
    end
  end

  defp split_source(%Source{} = source, dir) do
    segments = source.path |> Path.relative_to(dir) |> Path.rootname(@extension) |> Path.split()
    {dirs, [file]} = Enum.split(segments, -1)
    {dirs, {:"#{Macro.underscore(file)}", source}}
  end

  defp valid_segment?(<<first, rest::binary>>) when first in ?a..?z,
    do: rest |> String.to_charlist() |> Enum.all?(&(&1 in ?a..?z or &1 in ?0..?9 or &1 == ?_))

  defp valid_segment?(_segment), do: false

  defp aliases(grouped, config) do
    names = Enum.sort(for {[name | _rest], _definitions} <- grouped, uniq: true, do: name)

    case Enum.find(names, &Code.ensure_loaded?(Module.concat([&1]))) do
      nil -> {:ok, names}
      name -> {:error, {:component_directory_shadows_module, alias_dir(name, config), name}}
    end
  end

  defp alias_dir("Layouts", config), do: config.layouts
  defp alias_dir(name, config), do: Path.join(config.components, Macro.underscore(name))

  defp prefix_layouts(grouped) do
    Map.new(grouped, fn {segments, definitions} -> {["Layouts" | segments], definitions} end)
  end

  defp reject_layouts_directory(grouped, dir) do
    if Enum.any?(grouped, &match?({["Layouts" | _rest], _definitions}, &1)),
      do: {:error, {:component_directory_shadows_layouts, Path.join(dir, "layouts")}},
      else: :ok
  end

  defp reject_eex_layouts(dir) do
    case dir |> Path.join("**/*.html") |> Path.wildcard() |> Enum.sort() do
      [] -> :ok
      [path | _rest] -> {:error, {:eex_layout_unsupported, path}}
    end
  end

  defp short_name(module), do: module |> Module.split() |> List.last()

  defp setup_alias_names(ast) do
    {_ast, names} =
      Macro.prewalk(ast, [], fn
        {:alias, _meta, [target | opts]} = node, acc -> {node, alias_names(target, opts) ++ acc}
        node, acc -> {node, acc}
      end)

    names
  end

  defp alias_names({{:., _, [{:__aliases__, _, _}, :{}]}, _, targets}, _opts),
    do: Enum.flat_map(targets, &alias_names(&1, []))

  defp alias_names({:__aliases__, _meta, segments}, opts) do
    case Keyword.get(List.wrap(opts) |> List.flatten(), :as) do
      {:__aliases__, _, [as]} -> [Atom.to_string(as)]
      _no_as -> [segments |> List.last() |> Atom.to_string()]
    end
  end

  defp alias_names(_target, _opts), do: []
end
