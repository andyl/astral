defmodule Astral.Template do
  @moduledoc """
  Renders `.astral` templates with HEEx semantics.

  A `.astral` file is a small single-file template: an optional leading Elixir
  setup block delimited by `---`, followed by HEEx markup. Component files under
  the configured components directory become HEEx function components:
  `components/formatted_date.astral` is called as `<.formatted_date />` and
  `components/article/figure.astral` as `<Article.figure />`. See
  `Astral.Template.Namespace`.
  """

  alias Astral.Template.{Namespace, Source}

  @extension ".astral"

  @doc "Return true when a path points to an Astral template."
  @spec template?(String.t()) :: boolean()
  def template?(path), do: Path.extname(path) == @extension

  @doc "Render template source with project components and assigns."
  @spec render(Source.t(), map() | keyword(), Astral.Config.t()) ::
          {:ok, String.t()} | {:error, term()}
  def render(%Source{} = source, assigns, %Astral.Config{} = config) do
    render_source(source, :__astral_template__, assigns, config)
  end

  @doc "Render a `.astral` file with project components and assigns."
  @spec render_file(String.t(), map() | keyword(), Astral.Config.t()) ::
          {:ok, String.t()} | {:error, term()}
  def render_file(path, assigns, %Astral.Config{} = config) do
    with {:ok, source} <- File.read(path) do
      render_source(%Source{path: path, source: source}, :__astral_page__, assigns, config)
    end
  end

  @doc "Render a Markdown file as HEEx with project components and assigns."
  @spec render_markdown_file(String.t(), map() | keyword(), Astral.Config.t()) ::
          {:ok, String.t()} | {:error, term()}
  def render_markdown_file(path, assigns, %Astral.Config{} = config) do
    with {:ok, markdown} <- File.read(path),
         {:ok, source} <-
           Astral.Markdown.to_heex_html(markdown, file: path, markdown: config.markdown) do
      render_source(
        %Source{path: path, source: source},
        :__astral_markdown_page__,
        assigns,
        config
      )
    end
  end

  @doc "Evaluate a `.astral` setup block and return its Elixir binding."
  @spec setup_binding_file(String.t(), map() | keyword(), Astral.Config.t()) ::
          {:ok, keyword()} | {:error, term()}
  def setup_binding_file(path, assigns, %Astral.Config{} = config) do
    with {:ok, source} <- File.read(path) do
      setup_binding(%Source{path: path, source: source}, assigns, config)
    end
  end

  @doc "Return the template source currently being rendered in this process."
  @spec current_source() :: String.t() | nil
  defdelegate current_source(), to: Astral.Template.Context

  defp render_source(%Source{} = source, function, assigns, config) do
    with {:ok, namespace} <- Namespace.discover(config.components, config.root),
         :ok <- compile_namespace(namespace),
         module = module_name(config, function, namespace, source),
         {:ok, quoted} <- module_ast(module, namespace, [{function, source}]),
         {:ok, _module} <- Astral.Template.Compiler.compile(module, quoted, source.path) do
      html =
        Astral.Template.Context.with_source(source.path, fn ->
          rendered_to_html(apply(module, function, [assigns_map(assigns)]))
        end)

      {:ok, html}
    end
  end

  # All component modules compile as one unit: the root module comes first
  # because the others import it, and remote calls between directory modules
  # are verified only after every module in the unit exists.
  defp compile_namespace(%Namespace{} = namespace) do
    root = Namespace.root_module(namespace)

    [{root, namespace.root} | Enum.sort(namespace.modules)]
    |> Enum.reduce_while({:ok, []}, fn {module, definitions}, {:ok, acc} ->
      case module_ast(module, namespace, definitions) do
        {:ok, quoted} -> {:cont, {:ok, [quoted | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, quoted} ->
        block = {:__block__, [], Enum.reverse(quoted)}

        with {:ok, _root} <- Astral.Template.Compiler.compile(root, block, "components"),
             do: :ok

      error ->
        error
    end
  end

  defp module_ast(module, %Namespace{} = namespace, definitions) do
    with :ok <- check_setup_aliases(definitions, namespace) do
      do_module_ast(module, namespace, definitions)
    end
  rescue
    error in [SyntaxError, TokenMissingError] -> {:error, error}
  end

  defp check_setup_aliases(definitions, namespace) do
    Enum.reduce_while(definitions, :ok, fn {_function, %Source{} = source}, :ok ->
      {setup, _template, _line} = Source.split(source.source)

      case Namespace.check_setup_aliases(setup_ast(setup, source.path), namespace, source.path) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp do_module_ast(module, namespace, definitions) do
    definitions = Enum.map(definitions, &function_ast/1)
    root = Namespace.root_module(namespace)
    import_root = if module != root, do: quote(do: import(unquote(root)))
    aliases = Enum.map(namespace.aliases, &quote(do: alias(unquote(&1))))

    {:ok,
     quote generated: true do
       defmodule unquote(module) do
         use Phoenix.Component
         import Astral.Components
         import Astral.Route.Path, only: [path: 1, path: 2]
         import PhoenixIconify, only: [icon: 1]
         import Phoenix.HTML
         require Astral.Template.HEEx
         unquote(import_root)
         unquote_splicing(aliases)

         unquote_splicing(definitions)
       end
     end}
  end

  defp function_ast({function, %Source{} = source}) do
    {setup, template, line} = Source.split(source.source)
    template = clean_template!(template, source.path, line)
    setup_ast = setup_ast(setup, source.path)

    quote line: line do
      @file unquote(source.path)
      def unquote(function)(var!(assigns)) do
        var!(assigns) = Astral.Template.Context.scope_slots(var!(assigns))

        Astral.Template.Context.render(unquote(source.path), fn ->
          var!(assigns) = Map.new(var!(assigns))
          var!(assigns) = Map.put_new(var!(assigns), :__changed__, nil)
          _ = var!(assigns)
          unquote(setup_ast)
          _ = binding()
          Astral.Template.HEEx.compile(unquote(template), unquote(source.path), unquote(line))
        end)
      end
    end
  end

  defp setup_function_ast(setup_ast) do
    quote do
      def __astral_setup__(var!(assigns)) do
        var!(assigns) = Map.new(var!(assigns))
        var!(assigns) = Map.put_new(var!(assigns), :__changed__, nil)
        _ = var!(assigns)
        unquote(setup_ast)
        binding()
      end
    end
  end

  defp clean_template!(template, path, line) do
    case Astral.Template.Assets.extract(template, file: path, line: line) do
      {:ok, %{source: source}} -> source
      {:error, reason} -> raise CompileError, file: path, line: line, description: inspect(reason)
    end
  end

  defp setup_ast("", _path), do: quote(do: nil)

  defp setup_ast(source, path) do
    source
    |> Code.string_to_quoted!(file: path, line: 2, columns: true)
    |> rewrite_setup_assigns()
  end

  defp setup_binding(%Source{} = source, assigns, config) do
    {setup, _template, _line} = Source.split(source.source)
    module = module_name(config, :__astral_setup__, %Namespace{}, source)

    with {:ok, setup_ast} <- quoted_setup(setup, source.path),
         {:ok, _module} <-
           Astral.Template.Compiler.compile(
             module,
             setup_module_ast(module, setup_function_ast(setup_ast)),
             source.path
           ) do
      try do
        binding =
          Astral.Template.Context.with_source(source.path, fn ->
            module.__astral_setup__(assigns_map(assigns))
          end)

        {:ok, binding}
      rescue
        error in [RuntimeError, ArgumentError, KeyError, UndefinedFunctionError] ->
          {:error, error}
      end
    end
  end

  defp quoted_setup(source, path) do
    {:ok, setup_ast(source, path)}
  rescue
    error in [SyntaxError, TokenMissingError] -> {:error, error}
  end

  defp setup_module_ast(module, definition) do
    quote generated: true do
      defmodule unquote(module) do
        use Phoenix.Component
        import Astral.Components
        import Astral.Route.Path, only: [path: 1, path: 2]
        import PhoenixIconify, only: [icon: 1]
        import Phoenix.HTML

        unquote(definition)
      end
    end
  end

  defp rewrite_setup_assigns(ast) do
    Macro.prewalk(ast, fn
      {:@, meta, [{key, _key_meta, nil}]} when is_atom(key) ->
        assigns = {:var!, meta, [{:assigns, meta, nil}]}
        {{:., meta, [assigns, key]}, Keyword.put(meta, :no_parens, true), []}

      node ->
        node
    end)
  end

  defp assigns_map(assigns) when is_map(assigns), do: assigns
  defp assigns_map(assigns) when is_list(assigns), do: Map.new(assigns)

  defp rendered_to_html(rendered) do
    rendered
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp module_name(config, function, %Namespace{base: base}, %Source{} = source) do
    fingerprint = {config.root, function, base, source.path, source.source}

    hash =
      :sha256
      |> :crypto.hash(:erlang.term_to_binary(fingerprint))
      |> binary_part(0, 16)
      |> Base.encode16(case: :lower)

    Module.concat([Astral.Compiled.Template, "T#{hash}"])
  end
end
