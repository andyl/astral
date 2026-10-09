defmodule Astral.Template.Context do
  @moduledoc "Scopes source-relative resolution and page setup assigns across template rendering."

  @key {__MODULE__, :source}
  @page_assigns_key {__MODULE__, :page_assigns}

  @doc "Return the source file active in the current rendering process, or nil outside a scope."
  @spec current_source() :: String.t() | nil
  def current_source, do: Process.get(@key)

  @doc "Evaluate a callback with a source file active, restoring the caller's scope even on failure."
  @spec with_source(String.t(), (-> result)) :: result when result: var
  def with_source(path, fun) do
    previous = current_source()
    Process.put(@key, path)

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  @doc "Wrap HEEx slot callbacks to retain the caller's source when another component renders them."
  @spec scope_slots(map() | keyword()) :: map()
  def scope_slots(assigns) do
    caller = current_source()

    Map.new(assigns, fn
      {key, entries} when is_list(entries) -> {key, Enum.map(entries, &scope_slot(&1, caller))}
      pair -> pair
    end)
  end

  defp scope_slot(%{__slot__: _, inner_block: block} = slot, caller)
       when is_function(block, 2) and is_binary(caller) do
    %{slot | inner_block: fn changed, arg -> render(caller, fn -> block.(changed, arg) end) end}
  end

  defp scope_slot(value, _caller), do: value

  @doc "Preserve the source scope when HEEx evaluates the returned render's dynamic function later."
  @spec render(String.t(), (-> Phoenix.LiveView.Rendered.t())) :: Phoenix.LiveView.Rendered.t()
  def render(path, fun) do
    with_source(path, fn -> scope_dynamic(fun.(), path) end)
  end

  defp scope_dynamic(%Phoenix.LiveView.Rendered{dynamic: dynamic} = rendered, path)
       when is_function(dynamic, 1) do
    %{
      rendered
      | dynamic: fn track_changes -> with_source(path, fn -> dynamic.(track_changes) end) end
    }
  end

  defp scope_dynamic(rendered, _path), do: rendered

  @doc "Evaluate a page render and return its result with the assigns its setup block produced."
  @spec capture_page_assigns((-> result)) :: {result, map() | nil} when result: var
  def capture_page_assigns(fun) do
    previous = Process.delete(@page_assigns_key)

    try do
      result = fun.()
      {result, Process.get(@page_assigns_key)}
    after
      if previous,
        do: Process.put(@page_assigns_key, previous),
        else: Process.delete(@page_assigns_key)
    end
  end

  @doc "Record the assigns a page setup block produced for the enclosing capture."
  @spec put_page_assigns(map()) :: :ok
  def put_page_assigns(assigns) do
    Process.put(@page_assigns_key, Map.delete(assigns, :__changed__))
    :ok
  end
end
