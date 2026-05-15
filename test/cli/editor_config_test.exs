defmodule Ragex.CLI.EditorConfigTest do
  use ExUnit.Case, async: true

  alias Ragex.CLI.EditorConfig

  @test_dir Path.join(System.tmp_dir!(), "ragex_editor_test_#{:rand.uniform(100_000)}")

  setup do
    File.mkdir_p!(@test_dir)
    # Create a fake ragex-mcp binary
    bin_dir = Path.join(@test_dir, "bin")
    File.mkdir_p!(bin_dir)
    bin_path = Path.join(bin_dir, "ragex-mcp")
    File.write!(bin_path, "#!/bin/bash\necho test")
    File.chmod!(bin_path, 0o755)

    on_exit(fn -> File.rm_rf!(@test_dir) end)
    {:ok, bin: bin_path}
  end

  describe "all_editors/0" do
    test "returns 7 editors" do
      editors = EditorConfig.all_editors()
      assert map_size(editors) == 7
      assert Map.has_key?(editors, :claude)
      assert Map.has_key?(editors, :neovim)
      assert Map.has_key?(editors, :cursor)
    end
  end

  describe "editor_choices/0" do
    test "returns sorted list of {name, key} tuples" do
      choices = EditorConfig.editor_choices()
      assert is_list(choices)
      assert length(choices) == 7
      assert Enum.all?(choices, fn {name, key} -> is_binary(name) and is_atom(key) end)
    end
  end

  describe "detect_editors/1" do
    test "detects Claude Code config" do
      File.write!(Path.join(@test_dir, ".mcp.json"), "{}")
      detected = EditorConfig.detect_editors(@test_dir)
      keys = Enum.map(detected, fn {k, _} -> k end)
      assert :claude in keys
    end

    test "detects Cursor config" do
      File.mkdir_p!(Path.join(@test_dir, ".cursor"))
      detected = EditorConfig.detect_editors(@test_dir)
      keys = Enum.map(detected, fn {k, _} -> k end)
      assert :cursor in keys
    end

    test "detects NeoVim config" do
      File.write!(Path.join(@test_dir, ".nvim-mcp.json"), "{}")
      detected = EditorConfig.detect_editors(@test_dir)
      keys = Enum.map(detected, fn {k, _} -> k end)
      assert :neovim in keys
    end

    test "returns empty for clean directory" do
      clean = Path.join(@test_dir, "clean_#{:rand.uniform(100_000)}")
      File.mkdir_p!(clean)
      assert EditorConfig.detect_editors(clean) == []
    end
  end

  describe "generate/3" do
    test "generates Claude Code config", %{bin: bin} do
      assert {:ok, path} = EditorConfig.generate(:claude, @test_dir, ragex_bin: bin)
      assert File.exists?(path)
      content = File.read!(path) |> :json.decode()
      assert get_in(content, ["mcpServers", "ragex", "command"]) == bin
    end

    test "generates Cursor config", %{bin: bin} do
      assert {:ok, path} = EditorConfig.generate(:cursor, @test_dir, ragex_bin: bin)
      assert String.contains?(path, ".cursor/mcp.json")
      assert File.exists?(path)
    end

    test "generates NeoVim config", %{bin: bin} do
      assert {:ok, path} = EditorConfig.generate(:neovim, @test_dir, ragex_bin: bin)
      assert String.ends_with?(path, ".nvim-mcp.json")
      content = File.read!(path) |> :json.decode()
      assert get_in(content, ["mcpServers", "ragex", "command"]) == bin
    end

    test "generates VS Code config with nested mcp.servers", %{bin: bin} do
      assert {:ok, path} = EditorConfig.generate(:vscode, @test_dir, ragex_bin: bin)
      content = File.read!(path) |> :json.decode()
      assert get_in(content, ["mcp", "servers", "ragex", "command"]) == bin
    end

    test "generates Zed config with context_servers", %{bin: bin} do
      assert {:ok, path} = EditorConfig.generate(:zed, @test_dir, ragex_bin: bin)
      content = File.read!(path) |> :json.decode()
      ragex_config = get_in(content, ["context_servers", "ragex"])
      assert ragex_config["command"]["path"] == bin
    end

    test "merges into existing config without overwriting", %{bin: bin} do
      config_path = Path.join(@test_dir, ".mcp.json")

      File.write!(
        config_path,
        :json.encode(%{"mcpServers" => %{"other" => %{"command" => "other-tool"}}})
        |> IO.iodata_to_binary()
      )

      assert {:ok, _} = EditorConfig.generate(:claude, @test_dir, ragex_bin: bin)
      content = File.read!(config_path) |> :json.decode()

      # Original entry preserved
      assert get_in(content, ["mcpServers", "other", "command"]) == "other-tool"
      # Ragex added
      assert get_in(content, ["mcpServers", "ragex", "command"]) == bin
    end

    test "returns error for unknown editor" do
      assert {:error, {:unknown_editor, :brainfuck}} =
               EditorConfig.generate(:brainfuck, @test_dir)
    end
  end

  describe "generate_all/2" do
    test "generates for detected editors", %{bin: bin} do
      File.write!(Path.join(@test_dir, ".mcp.json"), "{}")
      results = EditorConfig.generate_all(@test_dir, ragex_bin: bin)
      assert match?(%{claude: {:ok, _}}, results)
    end

    test "generates Claude Code by default when nothing detected", %{bin: bin} do
      clean = Path.join(@test_dir, "clean_#{:rand.uniform(100_000)}")
      File.mkdir_p!(clean)
      # Copy bin
      bin_dir = Path.join(clean, "bin")
      File.mkdir_p!(bin_dir)
      File.cp!(bin, Path.join(bin_dir, "ragex-mcp"))

      results = EditorConfig.generate_all(clean)
      assert Map.has_key?(results, :claude)
    end
  end
end
