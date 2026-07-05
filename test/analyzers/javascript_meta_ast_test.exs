defmodule Ragex.Analyzers.JavaScriptMetaASTTest do
  use ExUnit.Case, async: true

  alias Metastatic.Adapters.JavaScript, as: JSAdapter
  alias Ragex.Analyzers.MetaASTExtractor

  describe "file_extensions/0" do
    test "covers all JS/TS variants" do
      exts = JSAdapter.file_extensions()
      assert ".js" in exts
      assert ".ts" in exts
      assert ".jsx" in exts
      assert ".tsx" in exts
    end
  end

  describe "parse/1" do
    test "returns {:ok, meta_ast}" do
      source = """
      function hello(name) {
        return name;
      }
      """

      assert {:ok, ast} = JSAdapter.parse(source)
      assert match?({:container, _, _}, ast)
    end

    test "file-level container is always present" do
      assert {:ok, ast} = JSAdapter.parse("const x = 1;")
      assert match?({:container, _, _}, ast)
    end
  end

  describe "to_meta/1" do
    test "is an identity pass returning {:ok, ast, %{}}" do
      {:ok, ast} = JSAdapter.parse("function f() {}")
      assert {:ok, ^ast, %{}} = JSAdapter.to_meta(ast)
    end
  end

  describe "function extraction via parse/1" do
    test "function declaration is emitted as :function_def" do
      source = "function greet(name, age) { return name; }"
      {:ok, ast} = JSAdapter.parse(source)

      func_defs = collect_nodes(ast, :function_def)

      assert Enum.any?(func_defs, fn {:function_def, meta, _} ->
               Keyword.get(meta, :name) == "greet"
             end)
    end

    test "arrow function is emitted as :function_def" do
      source = "const add = (a, b) => a + b;"
      {:ok, ast} = JSAdapter.parse(source)

      func_defs = collect_nodes(ast, :function_def)

      assert Enum.any?(func_defs, fn {:function_def, meta, _} ->
               Keyword.get(meta, :name) == "add"
             end)
    end

    test "class method is emitted as :function_def" do
      source = """
      class Foo {
        bar(x) { return x; }
      }
      """

      {:ok, ast} = JSAdapter.parse(source)
      func_defs = collect_nodes(ast, :function_def)

      assert Enum.any?(func_defs, fn {:function_def, meta, _} ->
               Keyword.get(meta, :name) == "bar"
             end)
    end

    test "parameter count is reflected in :params meta" do
      source = "function three(a, b, c) {}"
      {:ok, ast} = JSAdapter.parse(source)
      func_defs = collect_nodes(ast, :function_def)

      three =
        Enum.find(func_defs, fn {:function_def, meta, _} ->
          Keyword.get(meta, :name) == "three"
        end)

      assert three != nil
      {:function_def, meta, _} = three
      assert length(Keyword.get(meta, :params, [])) == 3
    end
  end

  describe "import extraction" do
    test "ES6 import is emitted as :import node" do
      source = ~s(import React from 'react';)
      {:ok, ast} = JSAdapter.parse(source)

      imports = collect_nodes(ast, :import)

      assert Enum.any?(imports, fn {:import, meta, _} ->
               Keyword.get(meta, :source) == "react"
             end)
    end

    test "require() is emitted as :import node" do
      source = ~s|const fs = require('fs');|
      {:ok, ast} = JSAdapter.parse(source)

      imports = collect_nodes(ast, :import)

      assert Enum.any?(imports, fn {:import, meta, _} ->
               Keyword.get(meta, :source) == "fs"
             end)
    end

    test "import type is recorded correctly" do
      {:ok, ast} = JSAdapter.parse(~s|import x from 'mod';|)
      imports = collect_nodes(ast, :import)
      [imp | _] = imports
      {:import, meta, _} = imp
      assert Keyword.get(meta, :import_type) == :es6_import
    end
  end

  describe "class extraction" do
    test "class produces :container node with container_type: :class" do
      source = """
      class Animal {
        speak() {}
      }
      """

      {:ok, ast} = JSAdapter.parse(source)
      containers = collect_nodes(ast, :container)

      assert Enum.any?(containers, fn {:container, meta, _} ->
               Keyword.get(meta, :name) == "Animal" and
                 Keyword.get(meta, :container_type) == :class
             end)
    end
  end

  describe "TypeScript type stripping" do
    test "typed params are still counted correctly" do
      source = "function typed(name: string, count: number): void {}"
      {:ok, ast} = JSAdapter.parse(source)
      func_defs = collect_nodes(ast, :function_def)

      typed =
        Enum.find(func_defs, fn {:function_def, meta, _} ->
          Keyword.get(meta, :name) == "typed"
        end)

      assert typed != nil
      {:function_def, meta, _} = typed
      # 2 params despite TypeScript type annotations
      assert length(Keyword.get(meta, :params, [])) == 2
    end
  end

  describe "MetaASTExtractor integration" do
    test "extract/2 works on a Document built from JavaScript source" do
      source = """
      import lodash from 'lodash';

      class Service {
        fetch(url) { return url; }
        post(url, data) {}
      }

      function helper(x) { return x; }
      """

      {:ok, ast} = JSAdapter.parse(source)

      doc = %Metastatic.Document{
        ast: ast,
        language: :javascript,
        metadata: %{},
        original_source: source
      }

      assert {:ok, result} = MetaASTExtractor.extract(doc, "service.js")

      # File-level or class container
      assert match?([_ | _], result.modules)

      # helper + fetch + post
      func_names = Enum.map(result.functions, fn f -> f.name end)
      assert :helper in func_names
      assert :fetch in func_names
      assert :post in func_names

      # lodash import
      assert Enum.any?(result.imports, fn i -> i.to_module == "lodash" end)
    end
  end

  describe "LanguageSupport integration" do
    test "get_adapter(:javascript) returns the new adapter" do
      assert {:ok, Metastatic.Adapters.JavaScript} =
               Ragex.LanguageSupport.get_adapter(:javascript)
    end

    test ".js extension is now in metastatic_extensions list" do
      assert ".js" in Ragex.LanguageSupport.metastatic_extensions()
    end

    test ".ts extension is now in metastatic_extensions list" do
      assert ".ts" in Ragex.LanguageSupport.metastatic_extensions()
    end
  end

  # ---------------------------------------------------------------------------
  # Helper
  # ---------------------------------------------------------------------------

  defp collect_nodes(ast, type) when is_list(ast) do
    Enum.flat_map(ast, fn node -> collect_nodes(node, type) end)
  end

  defp collect_nodes({type, _meta, children} = node, type) when is_list(children),
    do: [node | collect_nodes(children, type)]

  defp collect_nodes({type, _meta, _children} = node, type), do: [node]

  defp collect_nodes({_other, _meta, children}, type) when is_list(children),
    do: collect_nodes(children, type)

  defp collect_nodes(_node, _type), do: []
end
