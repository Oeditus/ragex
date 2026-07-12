defmodule Ragex.Analysis.Cohesion do
  @moduledoc """
  Language-agnostic Cohesion analysis for modules (functional) and classes (OOP).

  Computes structural cohesion using internal method/function call graphs:
  - **Functional Cohesion Index (FCI)**: `1.0 / number_of_connected_components`.
  - **Tight Cohesion (TCC)**: `connected_pairs / total_possible_pairs`.
  """

  alias Ragex.Graph.Store

  @type cohesion_result :: %{
          module: atom(),
          file: String.t(),
          language: atom(),
          cohesion_score: float(),
          tight_cohesion: float(),
          components_count: non_neg_integer(),
          functional_cohesion_index: float(),
          functions_count: non_neg_integer(),
          components: [[tuple()]]
        }

  @doc """
  Analyzes cohesion for a specific module by name.
  """
  @spec analyze_module(atom()) :: {:ok, cohesion_result()} | {:error, term()}
  def analyze_module(module_name) when is_atom(module_name) do
    case Store.get_module(module_name) do
      nil ->
        {:error, {:module_not_found, module_name}}

      module_node_data ->
        file = Map.get(module_node_data, :file) || ""
        language = Map.get(module_node_data, :language) || :elixir

        functions = get_module_functions(module_name)

        if Enum.empty?(functions) do
          {:ok, empty_cohesion_result(module_name, file, language)}
        else
          edges = get_internal_calls(module_name, functions)
          components = find_connected_components(functions, edges)
          metrics = calculate_cohesion_metrics(functions, components)

          {:ok,
           Map.merge(metrics, %{
             module: module_name,
             file: file,
             language: language,
             components: components
           })}
        end
    end
  end

  @doc """
  Analyzes cohesion for all modules in a directory.
  """
  @spec analyze_directory(String.t()) :: {:ok, [cohesion_result()]} | {:error, term()}
  def analyze_directory(dir_path) do
    modules = Store.list_modules()

    dir_modules =
      modules
      |> Enum.filter(fn mod ->
        file = Map.get(mod.data, :file) || ""
        String.starts_with?(file, dir_path)
      end)
      |> Enum.map(fn mod ->
        case analyze_module(mod.id) do
          {:ok, res} -> res
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, dir_modules}
  end

  # Helpers

  defp get_module_functions(module_name) do
    Store.list_functions(module: module_name)
    |> Enum.map(fn func -> func.id end)
  end

  defp get_internal_calls(module_name, functions) do
    funcs_set = MapSet.new(functions)

    Store.list_edges(edge_type: :calls)
    |> Enum.filter(fn edge ->
      case {edge.from, edge.to} do
        {{:function, ^module_name, name_from, arity_from},
         {:function, ^module_name, name_to, arity_to}} ->
          key_from = {module_name, name_from, arity_from}
          key_to = {module_name, name_to, arity_to}
          MapSet.member?(funcs_set, key_from) and MapSet.member?(funcs_set, key_to)

        _ ->
          false
      end
    end)
    |> Enum.map(fn edge ->
      {{_, _, name_from, arity_from}, {_, _, name_to, arity_to}} = {edge.from, edge.to}
      {{module_name, name_from, arity_from}, {module_name, name_to, arity_to}}
    end)
  end

  defp empty_cohesion_result(module_name, file, language) do
    %{
      module: module_name,
      file: file,
      language: language,
      cohesion_score: 1.0,
      tight_cohesion: 1.0,
      components_count: 0,
      functional_cohesion_index: 1.0,
      functions_count: 0,
      components: []
    }
  end

  defp calculate_cohesion_metrics(functions, components) do
    n = length(functions)
    comps_count = length(components)

    fci = if comps_count == 0, do: 1.0, else: 1.0 / comps_count

    tcc =
      if n <= 1 do
        1.0
      else
        total_possible_pairs = div(n * (n - 1), 2)

        connected_pairs =
          components
          |> Enum.map(fn comp ->
            s = length(comp)
            div(s * (s - 1), 2)
          end)
          |> Enum.sum()

        connected_pairs / total_possible_pairs
      end

    cohesion_score = (fci + tcc) / 2.0

    %{
      cohesion_score: cohesion_score,
      tight_cohesion: tcc,
      components_count: comps_count,
      functional_cohesion_index: fci,
      functions_count: n
    }
  end

  defp find_connected_components(nodes, edges) do
    adj = Enum.reduce(nodes, %{}, fn n, acc -> Map.put(acc, n, MapSet.new()) end)

    adj =
      Enum.reduce(edges, adj, fn {u, v}, acc ->
        if Map.has_key?(acc, u) and Map.has_key?(acc, v) do
          acc
          |> Map.update!(u, &MapSet.put(&1, v))
          |> Map.update!(v, &MapSet.put(&1, u))
        else
          acc
        end
      end)

    {components, _visited} =
      Enum.reduce(nodes, {[], MapSet.new()}, fn node, {comps, visited} ->
        if MapSet.member?(visited, node) do
          {comps, visited}
        else
          comp = bfs(adj, MapSet.new([node]), [node])
          {[MapSet.to_list(comp) | comps], MapSet.union(visited, comp)}
        end
      end)

    components
  end

  defp bfs(_adj, visited, []), do: visited

  defp bfs(adj, visited, [curr | rest]) do
    neighbors = Map.get(adj, curr, MapSet.new())

    new_unvisited =
      neighbors
      |> MapSet.difference(visited)
      |> MapSet.to_list()

    new_visited = MapSet.union(visited, MapSet.new(new_unvisited))
    bfs(adj, new_visited, rest ++ new_unvisited)
  end
end
