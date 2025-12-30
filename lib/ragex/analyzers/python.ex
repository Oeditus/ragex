defmodule Ragex.Analyzers.Python do
  @moduledoc """
  Analyzes Python code to extract modules, functions, calls, and dependencies.

  Shells out to Python to use the ast module for parsing, then extracts
  information from the returned JSON.
  """

  @behaviour Ragex.Analyzers.Behaviour

  @python_script """
  import ast
  import json
  import sys

  def analyze(source_code):
      try:
          tree = ast.parse(source_code)
      except SyntaxError as e:
          return {"error": str(e)}
      
      result = {
          "modules": [],
          "functions": [],
          "calls": [],
          "imports": []
      }
      
      current_class = None
      
      for node in ast.walk(tree):
          # Module-level (treat file as module)
          if isinstance(node, ast.Module):
              pass  # We'll infer module from filename
          
          # Class definitions (treat as modules)
          elif isinstance(node, ast.ClassDef):
              current_class = node.name
              result["modules"].append({
                  "name": node.name,
                  "line": node.lineno,
                  "doc": ast.get_docstring(node)
              })
          
          # Function definitions
          elif isinstance(node, ast.FunctionDef) or isinstance(node, ast.AsyncFunctionDef):
              module = current_class if current_class else "__main__"
              result["functions"].append({
                  "name": node.name,
                  "arity": len(node.args.args),
                  "module": module,
                  "line": node.lineno,
                  "doc": ast.get_docstring(node),
                  "visibility": "private" if node.name.startswith("_") else "public"
              })
          
          # Imports
          elif isinstance(node, ast.Import):
              for alias in node.names:
                  result["imports"].append({
                      "to_module": alias.name,
                      "type": "import",
                      "line": node.lineno
                  })
          
          elif isinstance(node, ast.ImportFrom):
              if node.module:
                  result["imports"].append({
                      "to_module": node.module,
                      "type": "import_from",
                      "line": node.lineno
                  })
          
          # Function calls
          elif isinstance(node, ast.Call):
              if isinstance(node.func, ast.Name):
                  result["calls"].append({
                      "to_function": node.func.id,
                      "to_module": None,
                      "line": node.lineno
                  })
              elif isinstance(node.func, ast.Attribute):
                  if isinstance(node.func.value, ast.Name):
                      result["calls"].append({
                          "to_function": node.func.attr,
                          "to_module": node.func.value.id,
                          "line": node.lineno
                      })
      
      return result

  if __name__ == "__main__":
      source = sys.stdin.read()
      result = analyze(source)
      print(json.dumps(result))
  """

  @impl true
  def analyze(source, file_path) do
    case run_python_analyzer(source) do
      {:ok, data} ->
        if Map.has_key?(data, "error") do
          {:error, {:python_syntax_error, data["error"]}}
        else
          result = transform_python_result(data, file_path)
          {:ok, result}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def supported_extensions, do: [".py"]

  # Private functions

  defp run_python_analyzer(source) do
    # The @python_script already has the __main__ block that reads stdin and prints JSON
    # We just need to use it directly

    # Create temp files for script and source
    script_file =
      System.tmp_dir!() |> Path.join("ragex_script_#{:erlang.unique_integer([:positive])}.py")

    source_file =
      System.tmp_dir!() |> Path.join("ragex_source_#{:erlang.unique_integer([:positive])}.py")

    try do
      File.write!(script_file, @python_script)
      File.write!(source_file, source)

      # Run Python with stdin redirected from source file
      case System.cmd("sh", ["-c", "python3 #{script_file} < #{source_file}"],
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          case Jason.decode(output) do
            {:ok, data} -> {:ok, data}
            {:error, reason} -> {:error, {:json_decode_error, reason}}
          end

        {error_output, _exit_code} ->
          {:error, {:python_error, error_output}}
      end
    after
      File.rm(script_file)
      File.rm(source_file)
    end
  rescue
    e -> {:error, {:system_cmd_error, Exception.message(e)}}
  end

  defp transform_python_result(data, file_path) do
    # Infer module name from file path
    module_name = Path.basename(file_path, ".py") |> String.to_atom()

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

    # Add file-level module if there are top-level functions
    has_top_level = Enum.any?(data["functions"], &(&1["module"] == "__main__"))

    modules =
      if has_top_level do
        [
          %{
            name: module_name,
            file: file_path,
            line: 1,
            doc: nil,
            metadata: %{type: :file}
          }
          | modules
        ]
      else
        modules
      end

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

        %{
          name: String.to_atom(func["name"]),
          arity: func["arity"],
          module: module,
          file: file_path,
          line: func["line"],
          doc: func["doc"],
          visibility: String.to_atom(func["visibility"]),
          metadata: %{}
        }
      end)

    # Transform imports
    imports =
      data["imports"]
      |> Enum.map(fn imp ->
        %{
          from_module: module_name,
          to_module: String.to_atom(imp["to_module"]),
          type: String.to_atom(imp["type"])
        }
      end)

    # Transform calls
    calls =
      data["calls"]
      |> Enum.map(fn call ->
        %{
          from_module: module_name,
          from_function: :unknown,
          from_arity: 0,
          to_module:
            if(call["to_module"], do: String.to_atom(call["to_module"]), else: module_name),
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
end
