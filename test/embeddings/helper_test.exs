defmodule Ragex.Embeddings.HelperTest do
  use ExUnit.Case, async: false

  alias Ragex.Embeddings.Helper
  alias Ragex.Graph.Store

  @moduletag :embeddings
  @moduletag timeout: 120_000

  @skip_embedding Application.compile_env(:ragex, :skip_embedding_tests, true)

  setup do
    # Clear the graph before each test
    Store.clear()
    :ok
  end

  describe "generate_and_store_embeddings/1" do
    @tag skip: @skip_embedding, slow: true, reason: :embedding
    test "generates embeddings for modules and functions" do
      # Wait for model
      wait_for_ready()

      analysis_result = %{
        modules: [
          %{
            name: :TestModule,
            file: "test.ex",
            line: 1,
            doc: "A test module",
            metadata: %{}
          }
        ],
        functions: [
          %{
            name: :test_func,
            arity: 2,
            module: :TestModule,
            file: "test.ex",
            line: 5,
            doc: "A test function",
            visibility: :public,
            metadata: %{}
          }
        ],
        calls: [],
        imports: []
      }

      assert :ok = Helper.generate_and_store_embeddings(analysis_result)

      # Verify embeddings were stored
      {module_embedding, module_text} = Store.get_embedding(:module, :TestModule)
      assert is_list(module_embedding)
      assert length(module_embedding) == 384
      assert module_text =~ "Module: TestModule"

      {func_embedding, func_text} = Store.get_embedding(:function, {:TestModule, :test_func, 2})
      assert is_list(func_embedding)
      assert length(func_embedding) == 384
      assert func_text =~ "Function: test_func/2"
    end

    test "returns error when model not ready" do
      # Don't wait for model
      with false <- Helper.ready?() do
        analysis_result = %{modules: [], functions: [], calls: [], imports: []}

        assert {:error, :model_not_ready} = Helper.generate_and_store_embeddings(analysis_result)
      end
    end
  end

  describe "generate_module_embedding/1" do
    test "generates and stores embedding for a module" do
      wait_for_ready()

      module_data = %{
        name: :MyModule,
        file: "my_module.ex",
        line: 1,
        doc: "My module documentation",
        metadata: %{}
      }

      assert :ok = Helper.generate_module_embedding(module_data)

      {embedding, text} = Store.get_embedding(:module, :MyModule)
      assert is_list(embedding)
      assert length(embedding) == 384
      assert text =~ "Module: MyModule"
      assert text =~ "My module documentation"
    end
  end

  describe "generate_function_embedding/1" do
    test "generates and stores embedding for a function" do
      wait_for_ready()

      function_data = %{
        name: :calculate,
        arity: 2,
        module: :Math,
        file: "math.ex",
        line: 10,
        doc: "Calculates something",
        visibility: :public,
        metadata: %{}
      }

      assert :ok = Helper.generate_function_embedding(function_data)

      {embedding, text} = Store.get_embedding(:function, {:Math, :calculate, 2})
      assert is_list(embedding)
      assert length(embedding) == 384
      assert text =~ "Function: calculate/2"
      assert text =~ "Module: Math"
    end
  end

  describe "generate_batch_embeddings/2" do
    test "generates embeddings for multiple functions efficiently" do
      wait_for_ready()

      functions = [
        %{
          name: :func1,
          arity: 0,
          module: :Mod,
          file: "mod.ex",
          line: 1,
          visibility: :public,
          metadata: %{}
        },
        %{
          name: :func2,
          arity: 1,
          module: :Mod,
          file: "mod.ex",
          line: 5,
          visibility: :public,
          metadata: %{}
        },
        %{
          name: :func3,
          arity: 2,
          module: :Mod,
          file: "mod.ex",
          line: 10,
          visibility: :public,
          metadata: %{}
        }
      ]

      assert {:ok, 3} = Helper.generate_batch_embeddings(functions, :function)

      # Verify all were stored
      {emb1, _} = Store.get_embedding(:function, {:Mod, :func1, 0})
      {emb2, _} = Store.get_embedding(:function, {:Mod, :func2, 1})
      {emb3, _} = Store.get_embedding(:function, {:Mod, :func3, 2})

      assert length(emb1) == 384
      assert length(emb2) == 384
      assert length(emb3) == 384
    end
  end

  describe "ready?/0" do
    test "returns boolean" do
      result = Helper.ready?()
      assert is_boolean(result)
    end

    test "eventually becomes ready" do
      wait_for_ready()
      assert Helper.ready?() == true
    end
  end

  # Helper functions

  defp wait_for_ready(attempts \\ 50) do
    if Helper.ready?() do
      :ok
    else
      if attempts > 0 do
        Process.sleep(2000)
        wait_for_ready(attempts - 1)
      else
        flunk("Model did not become ready in time")
      end
    end
  end
end
