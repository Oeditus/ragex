defmodule Ragex.Analyzers.JavaScript do
  @moduledoc """
  Analyzes JavaScript and TypeScript code to extract modules, functions, calls, and dependencies.

  Uses `@babel/parser` inside a Node.js process to perform high-fidelity AST parsing,
  extracting information from the returned JSON.
  """

  @behaviour Ragex.Analyzers.Behaviour

  @impl true
  def analyze(source, file_path) do
    case run_js_analyzer(source) do
      {:ok, data} ->
        if Map.has_key?(data, "error") do
          {:error, {:javascript_syntax_error, data["error"]}}
        else
          result = transform_js_result(data, file_path)
          {:ok, result}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:analysis_error, Exception.message(e)}}
  end

  @impl true
  def supported_extensions, do: [".js", ".jsx", ".ts", ".tsx", ".mjs"]

  # Private functions

  defp run_js_analyzer(source) do
    priv_dir =
      try do
        Application.app_dir(:ragex, "priv")
      rescue
        _ -> "priv"
      end

    parser_script = Path.join([priv_dir, "js_parser", "parser.js"])

    source_file =
      System.tmp_dir!() |> Path.join("ragex_source_#{:erlang.unique_integer([:positive])}.js")

    try do
      File.write!(source_file, source)

      case System.cmd("sh", ["-c", "node #{parser_script} < #{source_file}"],
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          try do
            data = :json.decode(output)
            {:ok, data}
          rescue
            e -> {:error, {:json_decode_error, e}}
          end

        {error_output, _exit_code} ->
          {:error, {:node_error, error_output}}
      end
    after
      File.rm(source_file)
    end
  rescue
    e -> {:error, {:system_cmd_error, Exception.message(e)}}
  end

  defp transform_js_result(data, file_path) do
    module_name = Path.basename(file_path, Path.extname(file_path)) |> String.to_atom()

    # Transform modules (classes)
    modules =
      data["modules"]
      |> Enum.map(fn mod ->
        %{
          name: String.to_atom(mod["name"]),
          file: file_path,
          line: mod["line"],
          doc: mod["doc"],
          metadata: %{type: :class}
        }
      end)

    # Always add file-level module
    modules = [
      %{
        name: module_name,
        file: file_path,
        line: 1,
        doc: nil,
        metadata: %{type: :file}
      }
      | modules
    ]

    # Transform functions
    functions =
      data["functions"]
      |> Enum.map(fn func ->
        module =
          if func["module"] == "__main__" do
            module_name
          else
            String.to_atom(func["module"])
          end

        metadata = if func["arrow"], do: %{arrow_function: true}, else: %{}

        %{
          name: String.to_atom(func["name"]),
          arity: func["arity"],
          module: module,
          file: file_path,
          line: func["line"],
          doc: func["doc"],
          visibility: String.to_atom(func["visibility"]),
          metadata: metadata
        }
      end)

    # Transform imports
    imports =
      data["imports"]
      |> Enum.map(fn imp ->
        %{
          from_module: module_name,
          to_module: sanitize_module_name(imp["to_module"]),
          type: String.to_atom(imp["type"])
        }
      end)

    # Transform calls
    calls =
      data["calls"]
      |> Enum.map(fn call ->
        to_module =
          case call["to_module"] do
            nil -> module_name
            mod when is_binary(mod) -> String.to_atom(mod)
            _ -> module_name
          end

        %{
          from_module: module_name,
          from_function: :unknown,
          from_arity: 0,
          to_module: to_module,
          to_function: String.to_atom(call["to_function"]),
          to_arity: 0,
          line: call["line"]
        }
      end)

    %{
      modules: modules,
      functions: functions,
      calls: calls,
      imports: imports
    }
  end

  defp sanitize_module_name(module) when is_binary(module) do
    module
    |> String.replace(~r/^[@.\/]+/, "")
    |> String.replace("/", ".")
    |> String.to_atom()
  end
end
