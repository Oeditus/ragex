defmodule Ragex.Analyzers.Ruby do
  @moduledoc """
  Analyzes Ruby code to extract modules, functions, calls, and dependencies.

  Uses the Metastatic Ruby adapter for parsing, which shells out to Ruby's
  parser gem for robust AST generation.
  """

  @behaviour Ragex.Analyzers.Behaviour

  @ruby_script """
  # Suppress all warnings (especially parser version warnings)
  $VERBOSE = nil
  Warning[:deprecated] = false if Warning.respond_to?(:[]=)

  require 'json'
  require 'parser/current'

  # Suppress warnings about Ruby version
  Parser::Builders::Default.emit_lambda = true
  Parser::Builders::Default.emit_procarg0 = true
  Parser::Builders::Default.emit_encoding = true
  Parser::Builders::Default.emit_index = true

  class RubyAnalyzer
    def initialize
      @modules = []
      @functions = []
      @calls = []
      @imports = []
      @current_module = nil
      @current_class = nil
    end

    def analyze(source)
      begin
        ast = Parser::CurrentRuby.parse(source)
        process(ast) if ast
        {
          modules: @modules,
          functions: @functions,
          calls: @calls,
          imports: @imports
        }
      rescue Parser::SyntaxError => e
        { error: e.message }
      end
    end

    private

    def process(node)
      return unless node.is_a?(Parser::AST::Node)

      case node.type
      when :module
        process_module(node)
      when :class
        process_class(node)
      when :def, :defs
        process_method(node)
      when :send, :csend
        process_call(node)
      else
        node.children.each { |child| process(child) }
      end
    end

    def process_module(node)
      name = extract_const_name(node.children[0])
      @modules << {
        name: name,
        line: node.loc.line,
        type: 'module'
      }
      old_module = @current_module
      @current_module = name
      node.children[1..-1].each { |child| process(child) }
      @current_module = old_module
    end

    def process_class(node)
      name = extract_const_name(node.children[0])
      @modules << {
        name: name,
        line: node.loc.line,
        type: 'class'
      }
      old_class = @current_class
      @current_class = name
      node.children[2..-1].each { |child| process(child) }
      @current_class = old_class
    end

    def process_method(node)
      if node.type == :defs
        # Class method: def self.method_name
        name = node.children[1].to_s
        args = node.children[2]
      else
        # Instance method: def method_name
        name = node.children[0].to_s
        args = node.children[1]
      end

      arity = args.children.count { |arg| [:arg, :optarg, :restarg, :kwarg, :kwoptarg, :kwrestarg].include?(arg&.type) }
      
      @functions << {
        name: name,
        arity: arity,
        module: @current_class || @current_module || '__main__',
        line: node.loc.line,
        visibility: name.start_with?('_') ? 'private' : 'public'
      }

      # Process method body for calls
      body = node.type == :defs ? node.children[3] : node.children[2]
      process(body) if body
    end

    def process_call(node)
      receiver = node.children[0]
      method_name = node.children[1].to_s
      
      # Skip internal Ruby methods and operators
      return if method_name =~ /^[^a-zA-Z_]/

      to_module = if receiver.nil?
        nil
      elsif receiver.is_a?(Parser::AST::Node)
        case receiver.type
        when :const
          extract_const_name(receiver)
        when :lvar, :ivar, :cvar
          receiver.children[0].to_s
        else
          nil
        end
      else
        nil
      end

      @calls << {
        to_function: method_name,
        to_module: to_module,
        line: node.loc&.line || 0
      }

      # Process arguments
      node.children[2..-1].each { |child| process(child) }
    end

    def extract_const_name(node)
      return nil unless node.is_a?(Parser::AST::Node)
      
      case node.type
      when :const
        parent = node.children[0]
        name = node.children[1].to_s
        if parent
          "\#{extract_const_name(parent)}::\#{name}"
        else
          name
        end
      when :cbase
        ''
      else
        nil
      end
    end
  end

  analyzer = RubyAnalyzer.new
  source = STDIN.read
  result = analyzer.analyze(source)
  puts JSON.generate(result)
  """

  @impl true
  def analyze(source, file_path) do
    case run_ruby_analyzer(source) do
      {:ok, data} ->
        if Map.has_key?(data, "error") do
          {:error, {:ruby_syntax_error, data["error"]}}
        else
          result = transform_ruby_result(data, file_path)
          {:ok, result}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def supported_extensions, do: [".rb"]

  # Private functions

  defp run_ruby_analyzer(source) do
    script_file =
      System.tmp_dir!() |> Path.join("ragex_ruby_#{:erlang.unique_integer([:positive])}.rb")

    source_file =
      System.tmp_dir!() |> Path.join("ragex_source_#{:erlang.unique_integer([:positive])}.rb")

    try do
      File.write!(script_file, @ruby_script)
      File.write!(source_file, source)

      # Redirect stderr to /dev/null to avoid parser warnings breaking JSON
      case System.cmd("sh", ["-c", "ruby #{script_file} < #{source_file} 2>/dev/null"]) do
        {output, 0} ->
          try do
            data = :json.decode(output)
            {:ok, data}
          rescue
            e -> {:error, {:json_decode_error, e}}
          end

        {error_output, _exit_code} ->
          {:error, {:ruby_error, error_output}}
      end
    after
      File.rm(script_file)
      File.rm(source_file)
    end
  rescue
    e -> {:error, {:system_cmd_error, Exception.message(e)}}
  end

  defp transform_ruby_result(data, file_path) do
    # Infer module name from file path
    module_name = Path.basename(file_path, ".rb") |> String.to_atom()

    # Transform modules (classes and modules)
    modules =
      data["modules"]
      |> Enum.map(fn mod ->
        %{
          name: String.to_atom(mod["name"]),
          file: file_path,
          line: mod["line"],
          doc: nil,
          metadata: %{type: String.to_atom(mod["type"])}
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
          doc: nil,
          visibility: String.to_atom(func["visibility"]),
          metadata: %{}
        }
      end)

    # Transform calls
    calls =
      data["calls"]
      |> Enum.map(fn call ->
        to_module =
          case call["to_module"] do
            nil -> module_name
            mod when is_binary(mod) and mod != "" -> String.to_atom(mod)
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
      imports: []
    }
  end
end
