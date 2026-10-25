defmodule Astral.Renderer do
  @moduledoc """
  Renders Astral pages to HTML.
  """

  @doc "Render a page from a discovered site."
  @spec render_page(Astral.Site.t(), Astral.Page.t()) :: {:ok, String.t()} | {:error, term()}
  def render_page(site, page) do
    with {:ok, content} <- page_content(page, site),
         {:ok, html} <- render_layout(content, page, site) do
      Astral.PluginRunner.render_page(site.config.plugins, html, page, site)
    end
  end

  defp page_content(%{source_path: path} = page, site) do
    cond do
      Astral.Template.template?(path) ->
        Astral.Template.render_file(path, Astral.Page.assigns(page, site), site.config)

      Path.extname(path) == ".md" ->
        Astral.Template.render_markdown_file(path, Astral.Page.assigns(page, site), site.config)

      true ->
        {:ok, page.content.html}
    end
  end

  # `.astral` pages wrap themselves in a layout component.
  defp render_layout(content, %{source_path: path} = page, site) do
    if Astral.Template.template?(path),
      do: {:ok, content},
      else: Astral.Layout.render(content, page.content.layout, page, site)
  end
end
