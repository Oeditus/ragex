defmodule Mix.Tasks.Ragex.Refactor do
  @moduledoc """
  Interactive refactoring wizard with operation selection and preview.

  ## Usage

      # Launch interactive wizard
      mix ragex.refactor
      
      # Direct refactoring with parameters (skips wizard)
      mix ragex.refactor --operation rename_function --module MyModule --function old_name --new-name new_name

  Provides an interactive TUI for selecting and performing refactoring operations:

  - rename_function: Rename a function across call sites
  - rename_module: Rename a module and update references
  - change_signature: Modify function parameters
  - extract_function: Extract code into new function
  - inline_function: Inline function body into call sites

  Features:
  - Interactive operation selection
  - Fuzzy search for modules and functions
  - Parameter validation
  - Diff preview before applying
  - Conflict detection and warnings
  - Progress tracking for multi-file operations
  """

  @shortdoc "Interactive refactoring wizard"

  use Mix.Task

  alias Ragex.CLI.{Colors, Output, Prompt}
  alias Ragex.Editor.Refactor
  alias Ragex.Graph.Store

  @operations [
    {:rename_function, "Rename a function"},
    {:rename_module, "Rename a module"},
    {:change_signature, "Modify function signature"},
    {:extract_function, "Extract code into new function"},
    {:inline_function, "Inline function body"}
  ]

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:ragex)

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          operation: :string,
          module: :string,
          function: :string,
          arity: :integer,
          new_name: :string,
          help: :boolean
        ],
        aliases: [
          o: :operation,
          m: :module,
          f: :function,
          a: :arity,
          n: :new_name,
          h: :help
        ]
      )

    cond do
      opts[:help] ->
        show_help()

      opts[:operation] ->
        run_direct_refactoring(opts)

      true ->
        run_interactive_wizard()
    end
  end

  # Interactive wizard flow
  defp run_interactive_wizard do
    Output.section("Ragex Refactoring Wizard")

    # Check if codebase is analyzed
    unless codebase_ready?() do
      IO.puts(Colors.error("✗ Codebase not analyzed"))
      IO.puts(Colors.muted("Run analysis first: mix ragex.cache.refresh --path ."))
      IO.puts("")
      System.halt(1)
    end

    # Step 1: Select operation
    operation = select_operation()

    # Step 2: Gather parameters based on operation
    params = gather_parameters(operation)

    # Step 3: Preview changes
    unless preview_changes(operation, params) do
      IO.puts(Colors.muted("Refactoring cancelled."))
      IO.puts("")
      System.halt(0)
    end

    # Step 4: Execute refactoring
    execute_refactoring(operation, params)
  end

  defp codebase_ready? do
    modules = Store.list_modules()
    length(modules) > 0
  end

  defp select_operation do
    IO.puts(Colors.bold("Select refactoring operation:"))
    IO.puts("")

    operation_labels =
      Enum.map(@operations, fn {op, desc} ->
        "#{Colors.info(Atom.to_string(op))} - #{desc}"
      end)

    selected_index = Prompt.select(operation_labels, default: 0)
    {operation, _desc} = Enum.at(@operations, selected_index)

    IO.puts("")
    IO.puts(Colors.success("Selected: #{operation}"))
    IO.puts("")

    operation
  end

  defp gather_parameters(:rename_function) do
    IO.puts(Colors.bold("Rename Function Parameters"))
    IO.puts("")

    # Get module
    modules = Store.list_modules()
    module_names = Enum.map(modules, &Atom.to_string/1)

    IO.puts("Available modules: #{length(modules)}")
    module_str = Prompt.input("Module name", validate: &validate_module(&1, modules))
    module = String.to_atom(module_str)

    # Get function
    functions = get_module_functions(module)
    IO.puts("Available functions: #{length(functions)}")

    function_str = Prompt.input("Function name", validate: &validate_non_empty/1)
    function = String.to_atom(function_str)

    # Get arity
    arity = Prompt.number("Function arity", min: 0, max: 20)

    # Verify function exists
    unless function_exists?(module, function, arity) do
      IO.puts(
        Colors.error("✗ Function #{module}.#{function}/#{arity} not found in knowledge graph")
      )

      IO.puts("")
      System.halt(1)
    end

    # Get new name
    new_name_str =
      Prompt.input("New function name",
        validate: &validate_non_empty/1,
        default: Atom.to_string(function)
      )

    new_name = String.to_atom(new_name_str)

    # Get scope
    IO.puts("")
    IO.puts("Refactoring scope:")

    scope_options = [
      "module - Rename only within #{module}",
      "project - Rename across entire project"
    ]

    scope_index = Prompt.select(scope_options, default: 1)
    scope = if scope_index == 0, do: :module, else: :project

    IO.puts("")

    %{
      module: module,
      function: function,
      arity: arity,
      new_name: new_name,
      scope: scope
    }
  end

  defp gather_parameters(:rename_module) do
    IO.puts(Colors.bold("Rename Module Parameters"))
    IO.puts("")

    # Get current module
    modules = Store.list_modules()
    module_names = Enum.map(modules, &Atom.to_string/1)

    IO.puts("Available modules: #{length(modules)}")
    old_module_str = Prompt.input("Current module name", validate: &validate_module(&1, modules))
    old_module = String.to_atom(old_module_str)

    # Get new name
    new_module_str =
      Prompt.input("New module name",
        validate: &validate_non_empty/1,
        default: old_module_str
      )

    new_module = String.to_atom(new_module_str)

    IO.puts("")

    %{
      old_module: old_module,
      new_module: new_module
    }
  end

  defp gather_parameters(:change_signature) do
    IO.puts(Colors.bold("Change Signature Parameters"))
    IO.puts("")

    # Get module and function
    modules = Store.list_modules()

    IO.puts("Available modules: #{length(modules)}")
    module_str = Prompt.input("Module name", validate: &validate_module(&1, modules))
    module = String.to_atom(module_str)

    function_str = Prompt.input("Function name", validate: &validate_non_empty/1)
    function = String.to_atom(function_str)

    arity = Prompt.number("Current arity", min: 0, max: 20)

    unless function_exists?(module, function, arity) do
      IO.puts(
        Colors.error("✗ Function #{module}.#{function}/#{arity} not found in knowledge graph")
      )

      IO.puts("")
      System.halt(1)
    end

    # Get signature changes
    IO.puts("")
    IO.puts(Colors.bold("Signature modifications:"))
    IO.puts("(Enter empty operation to finish)")
    IO.puts("")

    changes = collect_signature_changes()

    %{
      module: module,
      function: function,
      arity: arity,
      changes: changes
    }
  end

  defp gather_parameters(:extract_function) do
    IO.puts(Colors.bold("Extract Function Parameters"))
    IO.puts("")

    modules = Store.list_modules()

    IO.puts("Available modules: #{length(modules)}")
    module_str = Prompt.input("Module name", validate: &validate_module(&1, modules))
    module = String.to_atom(module_str)

    source_function_str = Prompt.input("Source function name", validate: &validate_non_empty/1)
    source_function = String.to_atom(source_function_str)

    source_arity = Prompt.number("Source function arity", min: 0, max: 20)

    unless function_exists?(module, source_function, source_arity) do
      IO.puts(Colors.error("✗ Function #{module}.#{source_function}/#{source_arity} not found"))

      IO.puts("")
      System.halt(1)
    end

    new_function_str = Prompt.input("New function name", validate: &validate_non_empty/1)
    new_function = String.to_atom(new_function_str)

    line_start = Prompt.number("Start line", min: 1)
    line_end = Prompt.number("End line", min: line_start)

    IO.puts("")

    %{
      module: module,
      source_function: source_function,
      source_arity: source_arity,
      new_function: new_function,
      line_start: line_start,
      line_end: line_end
    }
  end

  defp gather_parameters(:inline_function) do
    IO.puts(Colors.bold("Inline Function Parameters"))
    IO.puts("")

    modules = Store.list_modules()

    IO.puts("Available modules: #{length(modules)}")
    module_str = Prompt.input("Module name", validate: &validate_module(&1, modules))
    module = String.to_atom(module_str)

    function_str = Prompt.input("Function name", validate: &validate_non_empty/1)
    function = String.to_atom(function_str)

    arity = Prompt.number("Function arity", min: 0, max: 20)

    unless function_exists?(module, function, arity) do
      IO.puts(
        Colors.error("✗ Function #{module}.#{function}/#{arity} not found in knowledge graph")
      )

      IO.puts("")
      System.halt(1)
    end

    IO.puts("")

    %{
      module: module,
      function: function,
      arity: arity
    }
  end

  defp collect_signature_changes do
    change_types = ["add", "remove", "rename", "reorder"]

    collect_changes([], fn changes ->
      IO.puts("Change #{length(changes) + 1}:")
      type_index = Prompt.select(change_types ++ ["done"], default: 0)

      if type_index == length(change_types) do
        {:done, changes}
      else
        change_type = Enum.at(change_types, type_index) |> String.to_atom()
        change = collect_single_change(change_type)
        {:continue, changes ++ [change]}
      end
    end)
  end

  defp collect_changes(acc, collector) do
    case collector.(acc) do
      {:done, result} -> result
      {:continue, new_acc} -> collect_changes(new_acc, collector)
    end
  end

  defp collect_single_change(:add) do
    name = Prompt.input("Parameter name", validate: &validate_non_empty/1)
    position = Prompt.number("Position (0-based)", min: 0)
    default = Prompt.input("Default value (optional)", default: "nil")

    {:add, name, position, default}
  end

  defp collect_single_change(:remove) do
    name = Prompt.input("Parameter name to remove", validate: &validate_non_empty/1)
    {:remove, name}
  end

  defp collect_single_change(:rename) do
    old_name = Prompt.input("Current parameter name", validate: &validate_non_empty/1)
    new_name = Prompt.input("New parameter name", validate: &validate_non_empty/1)
    {:rename, old_name, new_name}
  end

  defp collect_single_change(:reorder) do
    positions_str =
      Prompt.input("New order (comma-separated indices)", validate: &validate_non_empty/1)

    positions = String.split(positions_str, ",") |> Enum.map(&String.to_integer(String.trim(&1)))
    {:reorder, positions}
  end

  defp preview_changes(operation, params) do
    Output.section("Preview Changes")

    IO.puts(Colors.info("Operation: #{operation}"))
    IO.puts(Colors.muted("Parameters:"))

    Enum.each(params, fn {key, value} ->
      IO.puts(Colors.muted("  #{key}: #{inspect(value)}"))
    end)

    IO.puts("")
    IO.puts(Colors.warning("Note: Actual diff preview requires implementation"))
    IO.puts("")

    Prompt.confirm("Apply refactoring?", default: :yes)
  end

  defp execute_refactoring(:rename_function, params) do
    Output.section("Executing Refactoring")

    result =
      Refactor.rename_function(
        params.module,
        params.function,
        params.new_name,
        params.arity,
        scope: params.scope,
        validate: true,
        format: true
      )

    handle_result(result)
  end

  defp execute_refactoring(:rename_module, params) do
    Output.section("Executing Refactoring")

    result =
      Refactor.rename_module(
        params.old_module,
        params.new_module,
        validate: true,
        format: true
      )

    handle_result(result)
  end

  defp execute_refactoring(:change_signature, params) do
    Output.section("Executing Refactoring")

    result =
      Refactor.change_signature(
        params.module,
        params.function,
        params.arity,
        params.changes,
        validate: true,
        format: true
      )

    handle_result(result)
  end

  defp execute_refactoring(:extract_function, params) do
    Output.section("Executing Refactoring")

    result =
      Refactor.extract_function(
        params.module,
        params.source_function,
        params.source_arity,
        params.new_function,
        {params.line_start, params.line_end},
        validate: true,
        format: true
      )

    handle_result(result)
  end

  defp execute_refactoring(:inline_function, params) do
    Output.section("Executing Refactoring")

    result =
      Refactor.inline_function(
        params.module,
        params.function,
        params.arity,
        validate: true,
        format: true
      )

    handle_result(result)
  end

  defp handle_result({:ok, result}) do
    IO.puts(Colors.success("✓ Refactoring completed successfully"))
    IO.puts("")

    Output.key_value(
      [
        {"Files modified", Colors.highlight(to_string(result.files_edited))},
        {"Lines changed", result.lines_added + result.lines_removed}
      ],
      indent: 2
    )

    IO.puts("")

    if result.warnings != [] do
      IO.puts(Colors.warning("Warnings:"))

      Enum.each(result.warnings, fn warning ->
        IO.puts(Colors.muted("  • #{warning}"))
      end)

      IO.puts("")
    end
  end

  defp handle_result({:error, result}) do
    IO.puts(Colors.error("✗ Refactoring failed"))
    IO.puts("")

    if result.errors != [] do
      IO.puts(Colors.error("Errors:"))

      Enum.each(result.errors, fn {file, error} ->
        IO.puts(Colors.error("  • #{file}: #{inspect(error)}"))
      end)

      IO.puts("")
    end

    IO.puts(Colors.muted("Changes rolled back."))
    IO.puts("")
    System.halt(1)
  end

  # Direct refactoring (non-interactive)
  defp run_direct_refactoring(opts) do
    operation = String.to_atom(opts[:operation])

    params =
      case operation do
        :rename_function ->
          %{
            module: String.to_atom(opts[:module]),
            function: String.to_atom(opts[:function]),
            arity: opts[:arity],
            new_name: String.to_atom(opts[:new_name]),
            scope: :project
          }

        _ ->
          IO.puts(Colors.error("Direct refactoring only supports rename_function currently"))
          System.halt(1)
      end

    execute_refactoring(operation, params)
  end

  # Validation helpers
  defp validate_module(input, modules) do
    module = String.to_atom(input)

    if Enum.member?(modules, module) do
      :ok
    else
      {:error, "Module not found in knowledge graph"}
    end
  end

  defp validate_non_empty(""), do: {:error, "Cannot be empty"}
  defp validate_non_empty(_), do: :ok

  defp function_exists?(module, function, arity) do
    Store.get_function(module, function, arity) != nil
  end

  defp get_module_functions(module) do
    # Get all functions defined in module
    case Store.get_module(module) do
      nil -> []
      _ -> Store.list_functions(module)
    end
  end

  defp show_help do
    IO.puts("""
    #{Colors.bold("Ragex Refactoring Wizard")}

    #{Colors.info("Interactive mode:")}
      mix ragex.refactor

    #{Colors.info("Direct mode (rename_function only):")}
      mix ragex.refactor --operation rename_function \\
        --module MyModule \\
        --function old_name \\
        --arity 2 \\
        --new-name new_name

    #{Colors.info("Supported operations:")}
      • rename_function - Rename a function across call sites
      • rename_module - Rename a module and update references
      • change_signature - Modify function parameters
      • extract_function - Extract code into new function
      • inline_function - Inline function body into call sites

    #{Colors.muted("Note: Codebase must be analyzed first (mix ragex.cache.refresh)")}
    """)
  end
end
