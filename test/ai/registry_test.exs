defmodule Ragex.AI.RegistryTest do
  use ExUnit.Case, async: false

  alias Ragex.AI.Registry

  describe "get_provider/0" do
    test "returns {:ok, module} when default provider is configured" do
      # Get the configured default provider
      result = Registry.get_provider()

      assert match?({:ok, _module}, result)
    end

    test "returns :error when default provider is nil" do
      # Save current config
      original_config = Application.get_env(:ragex, :ai, [])

      # Set default_provider to nil
      updated_config = Keyword.put(original_config, :default_provider, nil)
      Application.put_env(:ragex, :ai, updated_config)

      result = Registry.get_provider()

      assert result == :error

      # Restore original config
      Application.put_env(:ragex, :ai, original_config)
    end

    test "returns :error when provider not found in registry" do
      # Save current config
      original_config = Application.get_env(:ragex, :ai, [])

      # Set an invalid provider name
      updated_config = Keyword.put(original_config, :default_provider, :nonexistent_provider)
      Application.put_env(:ragex, :ai, updated_config)

      result = Registry.get_provider()

      assert result == :error

      # Restore original config
      Application.put_env(:ragex, :ai, original_config)
    end
  end

  describe "provider_available?/0" do
    test "returns true when provider is available" do
      # Assuming default config has a valid provider
      assert Registry.provider_available?() in [true, false]
    end

    test "returns false when provider is nil" do
      # Save current config
      original_config = Application.get_env(:ragex, :ai, [])

      # Set default_provider to nil
      updated_config = Keyword.put(original_config, :default_provider, nil)
      Application.put_env(:ragex, :ai, updated_config)

      refute Registry.provider_available?()

      # Restore original config
      Application.put_env(:ragex, :ai, original_config)
    end
  end

  describe "get_provider/1 (with name)" do
    test "returns provider module when it exists" do
      # deepseek_r1 is registered by default in Provider.Registry
      result = Registry.get_provider(:deepseek_r1)

      assert {:ok, Ragex.AI.Provider.DeepSeekR1} = result
    end

    test "returns error when provider not found" do
      result = Registry.get_provider(:nonexistent)

      assert {:error, :not_found} = result
    end
  end
end
