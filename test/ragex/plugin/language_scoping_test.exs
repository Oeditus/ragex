defmodule Ragex.Plugin.LanguageScopingTest do
  use ExUnit.Case, async: true

  alias Ragex.Plugin.Registry

  # Scoping decisions are pure functions of (plugin entry, active languages),
  # so they are tested directly rather than by mutating the registry's global
  # active set. Mutating that state from a test made results order-dependent:
  # any concurrently-running test that read `list_tools/0` could observe the
  # temporarily-set languages.

  defp generic_entry do
    %{
      id: :generic,
      module: Ragex.Plugins.GitArchaeology,
      languages: [],
      tools: [%{name: "generic_tool", destruction_level: :none}]
    }
  end

  defp elixir_entry do
    %{
      id: :elixir_language,
      module: Ragex.Plugins.Languages.Elixir,
      languages: [:elixir],
      tools: [%{name: "propwise_analyze", destruction_level: :none}]
    }
  end

  describe "scoped_in?/2" do
    test "generic plugins are always in scope" do
      assert Registry.scoped_in?(generic_entry(), [])
      assert Registry.scoped_in?(generic_entry(), [:python])
      assert Registry.scoped_in?(generic_entry(), [:elixir])
    end

    test "language plugins are in scope when their language is active" do
      assert Registry.scoped_in?(elixir_entry(), [:elixir])
      assert Registry.scoped_in?(elixir_entry(), [:python, :elixir])
    end

    test "language plugins are out of scope when their language is inactive" do
      refute Registry.scoped_in?(elixir_entry(), [:python])
      refute Registry.scoped_in?(elixir_entry(), [:ruby, :go])
    end

    test "an empty active set disables scoping entirely" do
      assert Registry.scoped_in?(elixir_entry(), [])
    end
  end

  describe "advertised_tools/2" do
    test "generic plugins advertise their static tools regardless of scope" do
      assert Registry.advertised_tools(generic_entry(), [:python]) == generic_entry().tools
      assert Registry.advertised_tools(generic_entry(), []) == generic_entry().tools
    end

    test "language tools are hidden when their language is inactive" do
      names =
        Registry.advertised_tools(elixir_entry(), [:python])
        |> Enum.map(& &1.name)

      refute "propwise_analyze" in names
    end

    test "language tools appear when their language is active" do
      names =
        Registry.advertised_tools(elixir_entry(), [:elixir])
        |> Enum.map(& &1.name)

      assert "propwise_analyze" in names
    end

    test "an empty active set advertises every language tool" do
      names =
        Registry.advertised_tools(elixir_entry(), [])
        |> Enum.map(& &1.name)

      assert "propwise_analyze" in names
    end

    test "advertised tools always carry a destruction_level" do
      for active <- [[], [:elixir], [:python]] do
        for tool <- Registry.advertised_tools(elixir_entry(), active) do
          assert Map.has_key?(tool, :destruction_level)
        end
      end
    end
  end

  describe "registry integration" do
    test "plugins_for_language/1 returns the Elixir plugin for :elixir" do
      assert Ragex.Plugins.Languages.Elixir in Registry.plugins_for_language(:elixir)
    end

    test "plugins_for_language/1 returns nothing for an unserved language" do
      assert Registry.plugins_for_language(:cobol) == []
    end

    test "the shipped active set is empty, so nothing is scoped away" do
      assert Registry.active_languages() == []
    end

    test "language plugins expose their languages and availability" do
      entry =
        Registry.list_plugins()
        |> Enum.find(&(&1.id == :elixir_language))

      assert entry.languages == [:elixir]
      assert is_boolean(entry.available?)
    end

    test "generic plugins declare no languages" do
      entry =
        Registry.list_plugins()
        |> Enum.find(&(&1.id == :git_archaeology))

      assert entry.languages == []
    end
  end
end
