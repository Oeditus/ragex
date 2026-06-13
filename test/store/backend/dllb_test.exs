defmodule Ragex.Store.Backend.DllbTest do
  # async: false -- these mutate the global :ragex/:embedding_model env.
  use ExUnit.Case, async: false

  alias Ragex.Store.Backend.Dllb

  setup do
    original = Application.get_env(:ragex, :embedding_model)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:ragex, :embedding_model)
        model -> Application.put_env(:ragex, :embedding_model, model)
      end
    end)

    :ok
  end

  describe "schema_statements/0 vector index dimension" do
    test "uses the configured model's dimension (384-dim model)" do
      Application.put_env(:ragex, :embedding_model, :all_minilm_l6_v2)

      assert vector_index_ddl() ==
               "DEFINE VECTOR INDEX idx_source_embedding ON TABLE ast_node " <>
                 "FIELDS source_embedding DIMENSION 384 METRIC cosine"
    end

    test "tracks a 768-dim model" do
      Application.put_env(:ragex, :embedding_model, :all_mpnet_base_v2)
      assert vector_index_ddl() =~ "source_embedding DIMENSION 768 METRIC cosine"
    end

    test "falls back to the default model's dimension for an unknown model" do
      Application.put_env(:ragex, :embedding_model, :nonexistent_model)
      # The default model (all_minilm_l6_v2) is 384-dim.
      assert vector_index_ddl() =~ "source_embedding DIMENSION 384"
    end
  end

  describe "schema_statements/0 contents" do
    test "includes the full-text search indexes" do
      joined = Enum.join(Dllb.schema_statements(), " ")

      assert joined =~
               "DEFINE FULLTEXT INDEX idx_source_text ON TABLE ast_node FIELDS source_text"

      assert joined =~ "DEFINE FULLTEXT INDEX idx_docstring ON TABLE ast_node FIELDS docstring"
    end

    test "defines exactly one vector index (source_embedding only)" do
      vector_indexes =
        Dllb.schema_statements()
        |> Enum.filter(&String.contains?(&1, "DEFINE VECTOR INDEX"))

      assert [_] = vector_indexes
    end
  end

  defp vector_index_ddl do
    Enum.find(Dllb.schema_statements(), &String.contains?(&1, "DEFINE VECTOR INDEX"))
  end
end
