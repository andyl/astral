defmodule Astral.LayoutTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Process.put(:astral_layout_tmp, tmp_dir)
    :ok
  end

  test "wraps Markdown pages in the default layout component" do
    write("pages/index.md", "---\ntitle: Home\n---\nHello")

    write("layouts/default.astral", """
    <title>{@page.title}</title><main data-route={@route}>{render_slot(@inner_block)}</main>
    """)

    assert {:ok, _result} = Astral.build(root: tmp())

    assert read("dist/index.html") ==
             ~s(<title>Home</title><main data-route="/"><p>Hello</p></main>)
  end

  test "does not wrap .astral pages in the default layout" do
    write("pages/index.astral", "<p>Bare</p>")
    write("layouts/default.astral", "<main>{render_slot(@inner_block)}</main>")

    assert {:ok, _result} = Astral.build(root: tmp())
    assert read("dist/index.html") == "<p>Bare</p>"
  end

  test "resolves nested layouts by path and as remote components" do
    write("pages/index.md", "---\nlayout: blog/post\n---\nBody")
    write("pages/about.astral", ~S|<Layouts.Blog.post title="About">Text</Layouts.Blog.post>|)

    write(
      "layouts/base.astral",
      ~S|<html><title>{@title}</title>{render_slot(@inner_block)}</html>|
    )

    write("layouts/blog/post.astral", """
    <Layouts.base title={assigns[:title] || "Post"}><article>{render_slot(@inner_block)}</article></Layouts.base>
    """)

    assert {:ok, _result} = Astral.build(root: tmp())

    assert read("dist/index.html") ==
             "<html><title>Post</title><article><p>Body</p></article></html>"

    assert read("dist/about/index.html") ==
             "<html><title>About</title><article>Text</article></html>"
  end

  test "passes .astral page assigns to a layout through attribute spreading" do
    write("pages/404.astral", """
    ---
    assigns = assign(assigns, :title, "Page not found")
    ---
    <Layouts.default {assigns}><p>Missing</p></Layouts.default>
    """)

    write("pages/index.md", "---\ntitle: Home\n---\nBody")

    write("layouts/default.astral", """
    <title>{@title || "Site"}</title><main data-route={@route}>{render_slot(@inner_block)}</main>
    """)

    assert {:ok, _result} = Astral.build(root: tmp())

    assert read("dist/404.html") ==
             ~s(<title>Page not found</title><main data-route="/404/"><p>Missing</p></main>)

    assert read("dist/index.html") ==
             ~s(<title>Home</title><main data-route="/"><p>Body</p></main>)
  end

  test "accepts layout names with the .astral extension" do
    write("pages/index.md", "---\nlayout: page.astral\n---\nBody")
    write("layouts/page.astral", "<section>{render_slot(@inner_block)}</section>")

    assert {:ok, _result} = Astral.build(root: tmp())
    assert read("dist/index.html") == "<section><p>Body</p></section>"
  end

  test "renders without a layout when the site default is missing" do
    write("pages/index.md", "Body")

    assert {:ok, _result} = Astral.build(root: tmp())
    assert read("dist/index.html") == "<p>Body</p>"
  end

  test "rejects EEx layouts with the file to convert" do
    write("pages/index.md", "Body")
    write("layouts/default.html", "<main><%= @content %></main>")

    assert {:error, {:render_failed, _page, {:eex_layout_unsupported, path}}} =
             Astral.build(root: tmp())

    assert path == Path.join(tmp(), "layouts/default.html")
  end

  test "rejects a components directory named layouts" do
    write("pages/index.md", "Body")
    write("components/layouts/card.astral", "<div></div>")

    assert {:error, {:render_failed, _page, {:component_directory_shadows_layouts, dir}}} =
             Astral.build(root: tmp())

    assert dir == Path.join(tmp(), "components/layouts")
  end

  defp tmp, do: Process.get(:astral_layout_tmp) || raise("missing tmp_dir")

  defp read(path), do: File.read!(Path.join(tmp(), path))

  defp write(path, content) do
    path = Path.join(tmp(), path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
