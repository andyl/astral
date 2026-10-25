defmodule Astral.ErrorPage do
  @moduledoc """
  Development errors for Astral routes.

  A render failure becomes a `t:Code.diagnostic/1` that the dev server reports with
  `Volt.HMR.error/3`, so the browser shows it in Volt's error overlay, with a source
  frame when the failure points into the site. The error page itself only loads
  Volt's client, and keeps the error as plain text for clients without JavaScript.
  """

  @doc """
  Describe a development failure as a diagnostic.

  Pass `root:` to locate the failure only in files inside the site root.
  """
  @spec diagnostic(term(), keyword()) :: Code.diagnostic(:error)
  def diagnostic(reason, opts \\ []) do
    root = Path.expand(Keyword.get(opts, :root, File.cwd!()))
    {message, stacktrace} = message(reason)

    # A syntax or compile error's stack is the loader's, not the site's.
    {{file, line}, stacktrace} =
      case exception_location(reason, root) do
        nil -> {location(stacktrace, root), stacktrace}
        location -> {location, []}
      end

    %{
      severity: :error,
      message: message,
      file: file,
      position: line,
      span: nil,
      source: nil,
      stacktrace: stacktrace
    }
  end

  @doc "Render the error page for a diagnostic."
  @spec render(Code.diagnostic(:error)) :: String.t()
  def render(diagnostic) do
    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Astral development error</title>
      </head>
      <body>
        <noscript><pre>#{escape(text(diagnostic))}</pre></noscript>
      </body>
    </html>
    """
  end

  defp text(%{file: nil} = diagnostic), do: body(diagnostic)
  defp text(%{file: file, position: 0} = diagnostic), do: "#{file}\n#{body(diagnostic)}"

  defp text(%{file: file, position: line} = diagnostic),
    do: "#{file}:#{line}\n#{body(diagnostic)}"

  defp body(%{message: message, stacktrace: []}), do: message

  defp body(%{message: message, stacktrace: stacktrace}),
    do: message <> "\n\n" <> Exception.format_stacktrace(stacktrace)

  defp message({:missing_layout, path, layout}),
    do: {"Missing layout: could not find #{inspect(layout)} for #{path}", []}

  defp message({:eex_layout_unsupported, path}),
    do:
      {"EEx layouts are no longer supported: convert #{path} to a .astral layout component " <>
         "that renders the page with {render_slot(@inner_block)}", []}

  defp message({:component_alias_shadowed, path, name}),
    do:
      {"#{path} aliases #{name}, which is also a component directory, so <#{name}.*> " <>
         "calls would resolve to the alias. Rename the alias with `as:` or the directory.", []}

  defp message({:component_directory_shadows_module, dir, name}),
    do:
      {"Component directory #{dir} would shadow the #{name} module in templates. " <>
         "Rename the directory.", []}

  defp message({:component_directory_shadows_layouts, dir}),
    do: {"Component directory #{dir} clashes with the Layouts module. Rename the directory.", []}

  defp message({:invalid_component_directory, dir}),
    do:
      {"Invalid component directory #{dir}: use lowercase letters, digits and underscores, " <>
         "starting with a letter", []}

  defp message({:missing_pages_dir, path}),
    do: {"Missing pages directory: expected #{path}", []}

  defp message({:exception, exception, stacktrace}),
    do: {Exception.format_banner(:error, exception), stacktrace}

  defp message(%{__exception__: true} = exception),
    do: {Exception.format_banner(:error, exception), []}

  defp message({:invalid_frontmatter, value}),
    do: {"Invalid frontmatter: expected YAML to decode to a map, got: #{inspect(value)}", []}

  defp message(reason), do: {"Astral failed to render this route: #{inspect(reason)}", []}

  # Syntax and compile errors carry their location rather than a stack frame.
  defp exception_location({:exception, %{file: file, line: line}, _stacktrace}, root)
       when is_binary(file) and is_integer(line) and line > 0,
       do: source_location([file: file, line: line], root)

  defp exception_location(_reason, _root), do: nil

  # The first stack frame in a site source file, outside dependencies.
  defp location(stacktrace, root) do
    Enum.find_value(stacktrace, {nil, 0}, fn
      {_module, _function, _arity, info} -> source_location(info, root)
      _frame -> nil
    end)
  end

  defp source_location(info, root) do
    with file when not is_nil(file) <- info[:file],
         line when is_integer(line) and line > 0 <- info[:line],
         path = Path.expand(to_string(file)),
         true <- project_source?(path, root) do
      {path, line}
    else
      _other -> nil
    end
  end

  defp project_source?(path, root) do
    relative = Path.relative_to(path, root)

    relative != path and File.regular?(path) and
      not String.starts_with?(relative, ["deps/", "_build/"])
  end

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
