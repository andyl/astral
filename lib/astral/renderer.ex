defmodule Astral.Renderer do
  @moduledoc """
  Renders Astral pages to HTML.

  Page content renders before its layout is chosen, so a `.astral` page can
  select a layout from its setup block by assigning `:layout`. Layouts resolve
  in this order: the setup block's `:layout` assign, the page content's layout
  (Markdown frontmatter, or the entry or collection layout for dynamic entry
  pages), then the site default layout.
  """

  @doc "Render a page from a discovered site."
  @spec render_page(Astral.Site.t(), Astral.Page.t()) :: {:ok, String.t()} | {:error, term()}
  def render_page(site, page) do
    with {:ok, content, layout_name} <- page_content(page, site),
         {:ok, layout} <- page_layout(layout_name, page, site),
         {:ok, html} <- Astral.Layout.render(content, layout, page, site) do
      Astral.PluginRunner.render_page(site.config.plugins, html, page, site)
    end
  end

  defp page_content(%{source_path: path} = page, site) do
    cond do
      Astral.Template.template?(path) ->
        with {:ok, html, assigns} <-
               Astral.Template.render_page_file(path, page_assigns(page, site), site.config) do
          {:ok, html, setup_layout(assigns, page)}
        end

      Path.extname(path) == ".md" ->
        with {:ok, html} <-
               Astral.Template.render_markdown_file(path, page_assigns(page, site), site.config) do
          {:ok, html, page.content.layout}
        end

      true ->
        {:ok, page.content.html, page.content.layout}
    end
  end

  defp setup_layout(%{layout: layout}, _page) when not is_nil(layout), do: layout
  defp setup_layout(_assigns, page), do: page.content.layout

  defp page_assigns(page, site) do
    %{
      page: page.content,
      metadata: page.content.metadata,
      route: page.route_path,
      params: page.params,
      site: site,
      collections: site.entries,
      entry: page.entry,
      routes: site.routes
    }
    |> Map.merge(page.assigns)
  end

  defp page_layout(false, _page, _site), do: {:ok, nil}
  defp page_layout("none", _page, _site), do: {:ok, nil}
  defp page_layout("false", _page, _site), do: {:ok, nil}

  defp page_layout(nil, _page, site) do
    {:ok, Map.get(site.layouts, site.config.layout)}
  end

  defp page_layout(layout_name, page, site) do
    case Map.fetch(site.layouts, layout_name) do
      {:ok, layout} -> {:ok, layout}
      :error -> {:error, {:missing_layout, page.source_path, layout_name}}
    end
  end
end
