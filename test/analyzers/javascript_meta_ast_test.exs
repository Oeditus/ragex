defmodule Ragex.Analyzers.JavaScriptMetaASTTest do
  use ExUnit.Case, async: true

  alias Metastatic.Adapters.JavaScript, as: JSAdapter
  alias Metastatic.Adapters.TypeScript, as: TSAdapter
  alias Ragex.Analyzers.MetaASTExtractor
  alias Ragex.LanguageSupport

  describe "file_extensions/0" do
    test "covers all JS/TS variants across JS and TS adapters" do
      js_exts = JSAdapter.file_extensions()
      ts_exts = TSAdapter.file_extensions()

      assert ".js" in js_exts
      assert ".jsx" in js_exts
      assert ".mjs" in js_exts
      assert ".cjs" in js_exts
      assert ".ts" in ts_exts
      assert ".tsx" in ts_exts
    end
  end

  describe "parse/1 and to_meta/1" do
    test "parse/1 produces Babel AST JSON and to_meta/1 produces MetaAST" do
      source = """
      function hello(name) {
        return name;
      }
      """

      assert {:ok, native_ast} = JSAdapter.parse(source)
      assert is_map(native_ast)
      assert native_ast["type"] == "File"

      assert {:ok, meta_ast, _metadata} = JSAdapter.to_meta(native_ast)
      assert match?({:function_def, _, _}, meta_ast)
    end
  end

  describe "function extraction via MetaAST" do
    test "function declaration is emitted as :function_def" do
      source = "function greet(name, age) { return name; }"
      {:ok, ast} = parse_meta(source)

      func_defs = collect_nodes(ast, :function_def)

      assert Enum.any?(func_defs, fn {:function_def, meta, _} ->
               Keyword.get(meta, :name) == "greet"
             end)
    end

    test "arrow function is emitted as :lambda node" do
      source = "const add = (a, b) => a + b;"
      {:ok, ast} = parse_meta(source)

      lambdas = collect_nodes(ast, :lambda)

      assert Enum.any?(lambdas, fn {:lambda, meta, _} ->
               Keyword.get(meta, :arrow) == true
             end)
    end

    test "class method is emitted as :function_def" do
      source = """
      class Foo {
        bar(x) { return x; }
      }
      """

      {:ok, ast} = parse_meta(source)
      func_defs = collect_nodes(ast, :function_def)

      assert Enum.any?(func_defs, fn {:function_def, meta, _} ->
               Keyword.get(meta, :name) == "bar"
             end)
    end

    test "parameter count is reflected in params meta" do
      source = "function three(a, b, c) {}"
      {:ok, ast} = parse_meta(source)
      func_defs = collect_nodes(ast, :function_def)

      three =
        Enum.find(func_defs, fn {:function_def, meta, _} ->
          Keyword.get(meta, :name) == "three"
        end)

      assert three != nil
      {:function_def, _meta, children} = three
      # Children tuple contains [params, body]
      [params | _] = children
      assert length(params) == 3
    end
  end

  describe "import extraction" do
    test "ES6 import is emitted as :import node" do
      source = ~s(import React from 'react';)
      {:ok, ast} = parse_meta(source)

      imports = collect_nodes(ast, :import)

      assert Enum.any?(imports, fn {:import, meta, _} ->
               Keyword.get(meta, :source) == "react"
             end)
    end

    test "require() is emitted as :function_call node" do
      source = ~s|const fs = require('fs');|
      {:ok, ast} = parse_meta(source)

      calls = collect_nodes(ast, :function_call)

      assert Enum.any?(calls, fn {:function_call, meta, _} ->
               Keyword.get(meta, :name) == "require"
             end)
    end

    test "import type is recorded correctly" do
      {:ok, ast} = parse_meta(~s|import x from 'mod';|)
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

      {:ok, ast} = parse_meta(source)
      containers = collect_nodes(ast, :container)

      assert Enum.any?(containers, fn {:container, meta, _} ->
               Keyword.get(meta, :name) == "Animal" and
                 Keyword.get(meta, :container_type) == :class
             end)
    end
  end

  describe "TypeScript type handling" do
    test "typed params in TS adapter are extracted and counted correctly" do
      source = "function typed(name: string, count: number): void {}"
      {:ok, ast} = parse_meta(source, TSAdapter)
      func_defs = collect_nodes(ast, :function_def)

      typed =
        Enum.find(func_defs, fn {:function_def, meta, _} ->
          Keyword.get(meta, :name) == "typed"
        end)

      assert typed != nil
      {:function_def, _meta, [params | _]} = typed
      # 2 params despite TypeScript type annotations
      assert length(params) == 2
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

      {:ok, doc} = LanguageSupport.parse_document(source, :javascript)

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

    test "extract/2 works on a Document built from TypeScript source" do
      source = """
      import lodash from 'lodash';

      class Service {
        fetch(url: string): string { return url; }
        post(url: string, data: any): void {}
      }

      function helper(x: number): number { return x; }
      """

      {:ok, doc} = LanguageSupport.parse_document(source, :typescript)

      assert {:ok, result} = MetaASTExtractor.extract(doc, "service.ts")

      assert match?([_ | _], result.modules)

      func_names = Enum.map(result.functions, fn f -> f.name end)
      assert :helper in func_names
      assert :fetch in func_names
      assert :post in func_names

      assert Enum.any?(result.imports, fn i -> i.to_module == "lodash" end)
    end
  end

  describe "LanguageSupport integration" do
    test "get_adapter(:javascript) returns JS adapter" do
      assert {:ok, Metastatic.Adapters.JavaScript} =
               LanguageSupport.get_adapter(:javascript)
    end

    test "get_adapter(:typescript) returns TS adapter" do
      assert {:ok, Metastatic.Adapters.TypeScript} =
               LanguageSupport.get_adapter(:typescript)
    end

    test ".js extension is in metastatic_extensions list" do
      assert ".js" in LanguageSupport.metastatic_extensions()
    end

    test ".ts extension is in metastatic_extensions list" do
      assert ".ts" in LanguageSupport.metastatic_extensions()
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp parse_meta(source, adapter \\ JSAdapter) do
    with {:ok, native_ast} <- adapter.parse(source),
         {:ok, meta_ast, _meta} <- adapter.to_meta(native_ast) do
      {:ok, meta_ast}
    end
  end

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
