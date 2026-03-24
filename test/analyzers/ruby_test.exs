defmodule Ragex.Analyzers.RubyTest do
  use ExUnit.Case, async: true

  alias Ragex.Analyzers.Ruby, as: RubyAnalyzer

  # Ruby analyzer tests require Ruby and the parser gem to be installed.
  # They are tagged with :ruby and will be skipped if Ruby is not available.
  @ruby_available System.find_executable("ruby") != nil

  setup do
    if @ruby_available do
      :ok
    else
      {:ok, skip: true}
    end
  end

  describe "analyze/2" do
    @tag :ruby
    test "extracts class information" do
      unless @ruby_available, do: :skip

      source = """
      class Calculator
        def initialize(initial = 0)
          @value = initial
        end

        def add(x)
          @value += x
          self
        end

        def result
          @value
        end
      end
      """

      assert {:ok, result} = RubyAnalyzer.analyze(source, "calculator.rb")

      # Class should be in modules
      calc_class = Enum.find(result.modules, &(&1.name == :Calculator))
      assert calc_class != nil
      assert calc_class.metadata.type == :class

      # Methods should be functions
      assert Enum.count(result.functions) >= 3

      init = Enum.find(result.functions, &(&1.name == :initialize))
      assert init != nil
      assert init.module == :Calculator

      add_func = Enum.find(result.functions, &(&1.name == :add))
      assert add_func != nil
      assert add_func.arity == 1
    end

    @tag :ruby
    test "extracts module and nested class information" do
      unless @ruby_available, do: :skip

      source = """
      module Catalog
        class BookService
          def self.list(options = {})
            Book.all
          end
        end
      end
      """

      assert {:ok, result} = RubyAnalyzer.analyze(source, "book_service.rb")

      # Module should be extracted
      assert Enum.any?(result.modules, &(&1.name == :Catalog))

      # Nested class should be extracted
      assert Enum.any?(result.modules, &(&1.name == :BookService))

      # Class method should be extracted
      list_func = Enum.find(result.functions, &(&1.name == :list))
      assert list_func != nil
    end

    @tag :ruby
    test "extracts method calls" do
      unless @ruby_available, do: :skip

      source = """
      class Greeter
        def greet(name)
          puts "Hello, \#{name}"
          name.upcase
        end
      end
      """

      assert {:ok, result} = RubyAnalyzer.analyze(source, "greeter.rb")

      # Should detect calls
      assert result.calls != []

      # Check for specific calls
      assert Enum.any?(result.calls, &(&1.to_function == :puts))
    end

    @tag :ruby
    test "extracts top-level functions" do
      unless @ruby_available, do: :skip

      source = """
      def hello
        "world"
      end

      def greet(name, greeting = "Hello")
        "\#{greeting}, \#{name}"
      end
      """

      assert {:ok, result} = RubyAnalyzer.analyze(source, "test.rb")

      # File-level module should be created for top-level functions
      assert Enum.any?(result.modules, &(&1.name == :test))

      assert Enum.count(result.functions) == 2

      hello = Enum.find(result.functions, &(&1.name == :hello))
      assert hello.arity == 0
      assert hello.module == :test

      greet = Enum.find(result.functions, &(&1.name == :greet))
      assert greet.arity == 2
    end

    @tag :ruby
    test "handles syntax errors" do
      unless @ruby_available, do: :skip

      source = """
      def broken_function(
          this is broken
      """

      assert {:error, _} = RubyAnalyzer.analyze(source, "broken.rb")
    end

    @tag :ruby
    test "distinguishes public and private methods by convention" do
      unless @ruby_available, do: :skip

      source = """
      class MyClass
        def public_method
          "public"
        end

        def _private_method
          "private"
        end
      end
      """

      assert {:ok, result} = RubyAnalyzer.analyze(source, "test.rb")

      public = Enum.find(result.functions, &(&1.name == :public_method))
      assert public.visibility == :public

      private = Enum.find(result.functions, &(&1.name == :_private_method))
      assert private.visibility == :private
    end
  end

  describe "supported_extensions/0" do
    test "returns ruby file extensions" do
      assert [".rb"] = RubyAnalyzer.supported_extensions()
    end
  end

  describe "ruby availability" do
    test "can execute ruby" do
      if @ruby_available do
        assert System.find_executable("ruby") != nil
      else
        IO.puts("\nWarning: Ruby not found. Ruby analyzer tests will be skipped.")
        assert true
      end
    end
  end
end
