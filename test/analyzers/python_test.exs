defmodule Ragex.Analyzers.PythonTest do
  use ExUnit.Case, async: true

  alias Ragex.Analyzers.Python, as: PythonAnalyzer

  # Note: Python analyzer tests require Python 3 to be installed
  # They are tagged with :python and will be skipped if Python is not available
  @python_available System.find_executable("python3") != nil

  setup do
    if @python_available do
      :ok
    else
      {:ok, skip: true}
    end
  end

  describe "analyze/2" do
    @tag :python
    test "extracts module and function information" do
      unless @python_available, do: :skip

      source = """
      def hello():
          return "world"

      def greet(name, greeting="Hello"):
          return f"{greeting}, {name}"
      """

      assert {:ok, result} = PythonAnalyzer.analyze(source, "test.py")

      # File-level module should be created
      assert Enum.any?(result.modules, &(&1.name == :test))

      assert Enum.count(result.functions) == 2

      hello = Enum.find(result.functions, &(&1.name == :hello))
      assert hello.arity == 0
      assert hello.visibility == :public
      assert hello.module == :test

      greet = Enum.find(result.functions, &(&1.name == :greet))
      assert greet.arity == 2
      assert greet.visibility == :public
    end

    @tag :python
    test "extracts class information" do
      unless @python_available, do: :skip

      source = """
      class TestClass:
          '''A test class'''
          
          def __init__(self):
              self.value = 0
          
          def method(self, arg):
              return arg * 2
          
          def _private_method(self):
              return "private"
      """

      assert {:ok, result} = PythonAnalyzer.analyze(source, "test.py")

      # Class should be in modules
      test_class = Enum.find(result.modules, &(&1.name == :TestClass))
      assert test_class != nil
      assert test_class.doc == "A test class"
      assert test_class.metadata.type == :class

      # Methods should be functions
      assert Enum.count(result.functions) == 3

      init = Enum.find(result.functions, &(&1.name == :__init__))
      assert init.module == :TestClass
      # self
      assert init.arity == 1

      method = Enum.find(result.functions, &(&1.name == :method))
      # self, arg
      assert method.arity == 2

      private = Enum.find(result.functions, &(&1.name == :_private_method))
      assert private.visibility == :private
    end

    @tag :python
    test "extracts import information" do
      unless @python_available, do: :skip

      source = """
      import os
      import sys
      from pathlib import Path
      from typing import List, Dict

      def test():
          pass
      """

      assert {:ok, result} = PythonAnalyzer.analyze(source, "test.py")

      assert result.imports != []

      assert Enum.any?(result.imports, &(&1.to_module == :os && &1.type == :import))
      assert Enum.any?(result.imports, &(&1.to_module == :sys && &1.type == :import))
      assert Enum.any?(result.imports, &(&1.to_module == :pathlib && &1.type == :import_from))
    end

    @tag :python
    test "extracts function calls" do
      unless @python_available, do: :skip

      source = """
      def caller():
          print("Hello")
          len([1, 2, 3])
          os.path.join("a", "b")
      """

      assert {:ok, result} = PythonAnalyzer.analyze(source, "test.py")

      # Should detect some calls
      assert result.calls != []

      # Check for specific calls
      assert Enum.any?(result.calls, &(&1.to_function == :print))
      assert Enum.any?(result.calls, &(&1.to_function == :len))
    end

    @tag :python
    test "handles syntax errors" do
      unless @python_available, do: :skip

      source = """
      def broken_function(
          this is broken
      """

      assert {:error, {:python_syntax_error, _}} = PythonAnalyzer.analyze(source, "broken.py")
    end

    @tag :python
    test "handles async functions" do
      unless @python_available, do: :skip

      source = """
      async def async_function():
          await something()
          return "done"
      """

      assert {:ok, result} = PythonAnalyzer.analyze(source, "test.py")

      async_func = Enum.find(result.functions, &(&1.name == :async_function))
      assert async_func != nil
      assert async_func.arity == 0
    end

    @tag :python
    test "distinguishes public and private functions" do
      unless @python_available, do: :skip

      source = """
      def public_function():
          pass

      def _private_function():
          pass

      def __dunder_function__():
          pass
      """

      assert {:ok, result} = PythonAnalyzer.analyze(source, "test.py")

      public = Enum.find(result.functions, &(&1.name == :public_function))
      assert public.visibility == :public

      private = Enum.find(result.functions, &(&1.name == :_private_function))
      assert private.visibility == :private

      dunder = Enum.find(result.functions, &(&1.name == :__dunder_function__))
      assert dunder.visibility == :private
    end
  end

  describe "supported_extensions/0" do
    test "returns python file extensions" do
      assert [".py"] = PythonAnalyzer.supported_extensions()
    end
  end

  describe "python availability" do
    test "can execute python" do
      if @python_available do
        assert System.find_executable("python3") != nil
      else
        IO.puts("\nWarning: Python 3 not found. Python analyzer tests will be skipped.")
        assert true
      end
    end
  end
end
