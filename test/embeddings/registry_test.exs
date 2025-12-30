defmodule Ragex.Embeddings.RegistryTest do
  use ExUnit.Case, async: true

  alias Ragex.Embeddings.Registry

  describe "all/0" do
    test "returns all available models" do
      models = Registry.all()

      assert is_list(models)
      assert Enum.count(models) == 4

      # Check all expected models are present
      model_ids = Enum.map(models, & &1.id)
      assert :all_minilm_l6_v2 in model_ids
      assert :all_mpnet_base_v2 in model_ids
      assert :codebert_base in model_ids
      assert :paraphrase_multilingual in model_ids
    end

    test "returns models sorted by ID" do
      models = Registry.all()
      ids = Enum.map(models, & &1.id)

      assert ids == Enum.sort(ids)
    end

    test "each model has required fields" do
      for model <- Registry.all() do
        assert is_atom(model.id)
        assert is_binary(model.name)
        assert is_binary(model.repo)
        assert is_integer(model.dimensions)
        assert model.dimensions > 0
        assert is_integer(model.max_tokens)
        assert model.max_tokens > 0
        assert is_binary(model.description)
        assert model.type in [:sentence_transformer, :code_model, :multilingual]
        assert is_list(model.recommended_for)
      end
    end
  end

  describe "get/1" do
    test "returns model info for valid ID" do
      {:ok, model} = Registry.get(:all_minilm_l6_v2)

      assert model.id == :all_minilm_l6_v2
      assert model.name == "all-MiniLM-L6-v2"
      assert model.dimensions == 384
    end

    test "returns error for invalid ID" do
      assert {:error, :not_found} = Registry.get(:invalid_model)
    end

    test "works for all predefined models" do
      for model_id <- [
            :all_minilm_l6_v2,
            :all_mpnet_base_v2,
            :codebert_base,
            :paraphrase_multilingual
          ] do
        assert {:ok, model} = Registry.get(model_id)
        assert model.id == model_id
      end
    end
  end

  describe "get!/1" do
    test "returns model info for valid ID" do
      model = Registry.get!(:all_minilm_l6_v2)

      assert model.id == :all_minilm_l6_v2
      assert model.dimensions == 384
    end

    test "raises for invalid ID" do
      assert_raise ArgumentError, ~r/Unknown model ID/, fn ->
        Registry.get!(:invalid_model)
      end
    end
  end

  describe "find_by_repo/1" do
    test "finds model by repository name" do
      {:ok, model} = Registry.find_by_repo("sentence-transformers/all-MiniLM-L6-v2")

      assert model.id == :all_minilm_l6_v2
    end

    test "returns error for unknown repository" do
      assert {:error, :not_found} = Registry.find_by_repo("unknown/model")
    end

    test "is case sensitive" do
      assert {:error, :not_found} =
               Registry.find_by_repo("SENTENCE-TRANSFORMERS/ALL-MINILM-L6-V2")
    end
  end

  describe "by_type/1" do
    test "filters sentence transformer models" do
      models = Registry.by_type(:sentence_transformer)

      assert models != []
      assert Enum.all?(models, &(&1.type == :sentence_transformer))

      ids = Enum.map(models, & &1.id)
      assert :all_minilm_l6_v2 in ids
      assert :all_mpnet_base_v2 in ids
    end

    test "filters code models" do
      models = Registry.by_type(:code_model)

      assert models != []
      assert Enum.all?(models, &(&1.type == :code_model))

      ids = Enum.map(models, & &1.id)
      assert :codebert_base in ids
    end

    test "filters multilingual models" do
      models = Registry.by_type(:multilingual)

      assert models != []
      assert Enum.all?(models, &(&1.type == :multilingual))

      ids = Enum.map(models, & &1.id)
      assert :paraphrase_multilingual in ids
    end

    test "returns sorted results" do
      models = Registry.by_type(:sentence_transformer)
      ids = Enum.map(models, & &1.id)

      assert ids == Enum.sort(ids)
    end
  end

  describe "default/0" do
    test "returns the default model ID" do
      assert Registry.default() == :all_minilm_l6_v2
    end
  end

  describe "valid?/1" do
    test "returns true for valid model IDs" do
      assert Registry.valid?(:all_minilm_l6_v2)
      assert Registry.valid?(:all_mpnet_base_v2)
      assert Registry.valid?(:codebert_base)
      assert Registry.valid?(:paraphrase_multilingual)
    end

    test "returns false for invalid model IDs" do
      refute Registry.valid?(:invalid_model)
      refute Registry.valid?(:foo)
      refute Registry.valid?(:bar)
    end
  end

  describe "dimensions/1" do
    test "returns dimensions for valid model" do
      assert {:ok, 384} = Registry.dimensions(:all_minilm_l6_v2)
      assert {:ok, 768} = Registry.dimensions(:all_mpnet_base_v2)
      assert {:ok, 768} = Registry.dimensions(:codebert_base)
      assert {:ok, 384} = Registry.dimensions(:paraphrase_multilingual)
    end

    test "returns error for invalid model" do
      assert {:error, :not_found} = Registry.dimensions(:invalid_model)
    end
  end

  describe "compatible?/2" do
    test "returns true for models with same dimensions" do
      # Both 384 dimensions
      assert Registry.compatible?(:all_minilm_l6_v2, :paraphrase_multilingual)
      assert Registry.compatible?(:paraphrase_multilingual, :all_minilm_l6_v2)

      # Both 768 dimensions
      assert Registry.compatible?(:all_mpnet_base_v2, :codebert_base)
      assert Registry.compatible?(:codebert_base, :all_mpnet_base_v2)
    end

    test "returns false for models with different dimensions" do
      # 384 vs 768
      refute Registry.compatible?(:all_minilm_l6_v2, :all_mpnet_base_v2)
      refute Registry.compatible?(:all_mpnet_base_v2, :all_minilm_l6_v2)

      refute Registry.compatible?(:paraphrase_multilingual, :codebert_base)
      refute Registry.compatible?(:codebert_base, :paraphrase_multilingual)
    end

    test "returns false for invalid model IDs" do
      refute Registry.compatible?(:invalid_model, :all_minilm_l6_v2)
      refute Registry.compatible?(:all_minilm_l6_v2, :invalid_model)
      refute Registry.compatible?(:invalid1, :invalid2)
    end

    test "model is compatible with itself" do
      assert Registry.compatible?(:all_minilm_l6_v2, :all_minilm_l6_v2)
      assert Registry.compatible?(:codebert_base, :codebert_base)
    end
  end

  describe "recommendations/0" do
    test "returns formatted string with recommendations" do
      text = Registry.recommendations()

      assert is_binary(text)
      assert String.contains?(text, "all_minilm_l6_v2")
      assert String.contains?(text, "all_mpnet_base_v2")
      assert String.contains?(text, "codebert_base")
      assert String.contains?(text, "paraphrase_multilingual")
      assert String.contains?(text, "config :ragex")
      assert String.contains?(text, "RAGEX_EMBEDDING_MODEL")
    end
  end

  describe "model metadata consistency" do
    test "all models have unique IDs" do
      models = Registry.all()
      ids = Enum.map(models, & &1.id)

      assert length(ids) == length(Enum.uniq(ids))
    end

    test "all models have unique repositories" do
      models = Registry.all()
      repos = Enum.map(models, & &1.repo)

      assert length(repos) == length(Enum.uniq(repos))
    end

    test "all models have reasonable dimension counts" do
      for model <- Registry.all() do
        # Common embedding dimensions
        assert model.dimensions in [128, 256, 384, 512, 768, 1024, 1536]
      end
    end

    test "all models have positive max_tokens" do
      for model <- Registry.all() do
        assert model.max_tokens > 0
        # Reasonable upper bound
        assert model.max_tokens <= 2048
      end
    end

    test "all models have non-empty descriptions" do
      for model <- Registry.all() do
        assert String.length(model.description) > 10
      end
    end

    test "all models have recommendations" do
      for model <- Registry.all() do
        assert model.recommended_for != []
        assert Enum.all?(model.recommended_for, &is_binary/1)
      end
    end
  end
end
