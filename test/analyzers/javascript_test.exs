defmodule Ragex.Analyzers.JavaScriptTest do
  use ExUnit.Case, async: true

  alias Ragex.Analyzers.JavaScript, as: JavaScriptAnalyzer

  describe "analyze/2" do
    test "extracts function declarations" do
      source = """
      function hello() {
        return 'world';
      }

      function greet(name, greeting) {
        return greeting + ', ' + name;
      }

      async function asyncFunc() {
        return await something();
      }
      """

      assert {:ok, result} = JavaScriptAnalyzer.analyze(source, "test.js")

      # Should have file-level module
      assert Enum.any?(result.modules, &(&1.name == :test))

      assert Enum.count(result.functions) == 3

      hello = Enum.find(result.functions, &(&1.name == :hello))
      assert hello.arity == 0
      assert hello.module == :test

      greet = Enum.find(result.functions, &(&1.name == :greet))
      assert greet.arity == 2

      async_func = Enum.find(result.functions, &(&1.name == :asyncFunc))
      assert async_func.arity == 0
    end

    test "extracts arrow functions" do
      source = """
      const add = (a, b) => a + b;

      const multiply = (x, y) => {
        return x * y;
      };

      let square = (n) => n * n;
      var double = (n) => n * 2;
      """

      assert {:ok, result} = JavaScriptAnalyzer.analyze(source, "test.js")

      assert Enum.count(result.functions) >= 4

      add = Enum.find(result.functions, &(&1.name == :add))
      assert add.arity == 2
      assert add.metadata.arrow_function == true

      multiply = Enum.find(result.functions, &(&1.name == :multiply))
      assert multiply.arity == 2

      square = Enum.find(result.functions, &(&1.name == :square))
      assert square.arity == 1

      double = Enum.find(result.functions, &(&1.name == :double))
      assert double.arity == 1
    end

    test "extracts class definitions" do
      source = """
      class MyClass {
        constructor() {
          this.value = 0;
        }

        method(arg) {
          return arg * 2;
        }

        async asyncMethod() {
          return await fetch('data');
        }
      }

      export class ExportedClass {
        static staticMethod() {
          return 'static';
        }
      }
      """

      assert {:ok, result} = JavaScriptAnalyzer.analyze(source, "test.js")

      # Classes should be in modules
      my_class = Enum.find(result.modules, &(&1.name == :MyClass))
      assert my_class != nil
      assert my_class.metadata.type == :class

      exported = Enum.find(result.modules, &(&1.name == :ExportedClass))
      assert exported != nil

      # Methods should be functions
      constructor = Enum.find(result.functions, &(&1.name == :constructor))
      assert constructor != nil

      method = Enum.find(result.functions, &(&1.name == :method))
      assert method.arity == 1

      async_method = Enum.find(result.functions, &(&1.name == :asyncMethod))
      assert async_method != nil
    end

    test "extracts ES6 imports" do
      source = """
      import React from 'react';
      import { useState, useEffect } from 'react';
      import * as Utils from './utils';
      import './styles.css';

      function Component() {}
      """

      assert {:ok, result} = JavaScriptAnalyzer.analyze(source, "test.js")

      assert result.imports != []

      assert Enum.any?(result.imports, &(&1.to_module == :react && &1.type == :import))
      assert Enum.any?(result.imports, &(&1.to_module == :utils && &1.type == :import))
    end

    test "extracts CommonJS requires" do
      source = """
      const fs = require('fs');
      const path = require('path');
      const myModule = require('./my-module');

      function test() {}
      """

      assert {:ok, result} = JavaScriptAnalyzer.analyze(source, "test.js")

      assert result.imports != []

      assert Enum.any?(result.imports, &(&1.to_module == :fs && &1.type == :require))
      assert Enum.any?(result.imports, &(&1.to_module == :path && &1.type == :require))
    end

    test "extracts function calls" do
      source = """
      function caller() {
        console.log('hello');
        Math.random();
        helper();
        obj.method();
      }

      function helper() {
        return 42;
      }
      """

      assert {:ok, result} = JavaScriptAnalyzer.analyze(source, "test.js")

      # Should detect calls
      assert result.calls != []

      # Check for specific calls
      assert Enum.any?(result.calls, &(&1.to_module == :console && &1.to_function == :log))
      assert Enum.any?(result.calls, &(&1.to_module == :Math && &1.to_function == :random))
      assert Enum.any?(result.calls, &(&1.to_function == :helper))
      assert Enum.any?(result.calls, &(&1.to_module == :obj && &1.to_function == :method))
    end

    test "handles export statements" do
      source = """
      export function exportedFunc() {
        return 'exported';
      }

      export const exportedConst = (x) => x * 2;

      export class ExportedClass {
        method() {}
      }
      """

      assert {:ok, result} = JavaScriptAnalyzer.analyze(source, "test.js")

      exported_func = Enum.find(result.functions, &(&1.name == :exportedFunc))
      assert exported_func != nil

      exported_const = Enum.find(result.functions, &(&1.name == :exportedConst))
      assert exported_const != nil

      exported_class = Enum.find(result.modules, &(&1.name == :ExportedClass))
      assert exported_class != nil
    end

    test "distinguishes private functions by naming convention" do
      source = """
      function publicFunction() {}
      function _privateFunction() {}

      const publicConst = () => {};
      const _privateConst = () => {};
      """

      assert {:ok, result} = JavaScriptAnalyzer.analyze(source, "test.js")

      public_func = Enum.find(result.functions, &(&1.name == :publicFunction))
      assert public_func.visibility == :public

      private_func = Enum.find(result.functions, &(&1.name == :_privateFunction))
      assert private_func.visibility == :private
    end

    test "handles TypeScript files" do
      source = """
      interface User {
        name: string;
        age: number;
      }

      function greet(user: User): string {
        return `Hello, ${user.name}`;
      }

      const add = (a: number, b: number): number => a + b;
      """

      assert {:ok, result} = JavaScriptAnalyzer.analyze(source, "test.ts")

      # Should extract functions even with type annotations
      greet = Enum.find(result.functions, &(&1.name == :greet))
      assert greet != nil
      assert greet.arity == 1

      add = Enum.find(result.functions, &(&1.name == :add))
      assert add != nil
      assert add.arity == 2
    end

    test "handles empty files" do
      source = ""

      assert {:ok, result} = JavaScriptAnalyzer.analyze(source, "empty.js")

      # Should at least have a file module
      assert Enum.any?(result.modules, &(&1.name == :empty))
    end

    test "skips control flow keywords" do
      source = """
      function test() {
        if (condition) {
          for (let i = 0; i < 10; i++) {
            while (true) {
              switch (value) {
                case 1:
                  break;
              }
            }
          }
        }
      }
      """

      assert {:ok, result} = JavaScriptAnalyzer.analyze(source, "test.js")

      # Should not have calls for if, for, while, switch
      refute Enum.any?(result.calls, &(&1.to_function == :if))
      refute Enum.any?(result.calls, &(&1.to_function == :for))
      refute Enum.any?(result.calls, &(&1.to_function == :while))
      refute Enum.any?(result.calls, &(&1.to_function == :switch))
    end
  end

  describe "supported_extensions/0" do
    test "returns javascript and typescript file extensions" do
      extensions = JavaScriptAnalyzer.supported_extensions()
      assert ".js" in extensions
      assert ".jsx" in extensions
      assert ".ts" in extensions
      assert ".tsx" in extensions
      assert ".mjs" in extensions
    end
  end
end
