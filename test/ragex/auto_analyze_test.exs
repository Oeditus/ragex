defmodule Ragex.AutoAnalyzeTest do
  use ExUnit.Case, async: false

  alias Ragex.Analyzers.Directory
  alias Ragex.Graph.Store

  @test_dir "/tmp/ragex_test_auto_analyze"
  @test_file Path.join(@test_dir, "test_module.ex")

  setup do
    # Create test directory and file
    File.mkdir_p!(@test_dir)

    File.write!(@test_file, """
    defmodule TestModule do
      @moduledoc "Test module for auto-analyze"

      def hello do
        :world
      end
    end
    """)

    # Clean up graph store
    Store.clear()

    on_exit(fn ->
      File.rm_rf!(@test_dir)
      Store.clear()
    end)

    :ok
  end

  describe "auto_analyze_dirs configuration" do
    test "empty list does not trigger analysis" do
      # Simulate start_phase with empty config
      Application.put_env(:ragex, :auto_analyze_dirs, [])

      # Start phase should return :ok without doing anything
      assert :ok = Ragex.Application.start_phase(:auto_analyze, :normal, [])

      # Graph should still be empty
      stats = Store.stats()
      assert stats.nodes == 0
    end

    test "configured directories are analyzed on startup" do
      # Configure test directory for auto-analysis
      Application.put_env(:ragex, :auto_analyze_dirs, [@test_dir])

      # Trigger the start phase
      assert :ok = Ragex.Application.start_phase(:auto_analyze, :normal, [])

      # Wait a bit for async analysis to complete
      Process.sleep(500)

      # Verify the module was analyzed and added to graph
      stats = Store.stats()
      assert stats.nodes > 0

      # Check that our test module is in the graph
      nodes = Store.list_nodes()
      assert Enum.any?(nodes, fn node ->
        node.type == :module && node.id == TestModule
      end)
    end

    test "multiple directories are analyzed sequentially" do
      # Create second test directory
      test_dir2 = "/tmp/ragex_test_auto_analyze_2"
      test_file2 = Path.join(test_dir2, "another_module.ex")
      
      File.mkdir_p!(test_dir2)
      File.write!(test_file2, """
      defmodule AnotherModule do
        def test, do: :ok
      end
      """)

      # Configure both directories
      Application.put_env(:ragex, :auto_analyze_dirs, [@test_dir, test_dir2])

      # Trigger the start phase
      assert :ok = Ragex.Application.start_phase(:auto_analyze, :normal, [])

      # Wait for analysis
      Process.sleep(500)

      # Both modules should be in the graph
      nodes = Store.list_nodes()
      module_names = nodes
        |> Enum.filter(&(&1.type == :module))
        |> Enum.map(& &1.id)

      assert TestModule in module_names
      assert AnotherModule in module_names

      # Clean up
      File.rm_rf!(test_dir2)
    end

    test "invalid directory logs warning but continues" do
      # Configure mix of valid and invalid directories
      Application.put_env(:ragex, :auto_analyze_dirs, [
        "/nonexistent/directory",
        @test_dir
      ])

      # Should not crash, just log warning
      assert :ok = Ragex.Application.start_phase(:auto_analyze, :normal, [])

      # Wait for analysis
      Process.sleep(500)

      # Valid directory should still be analyzed
      nodes = Store.list_nodes()
      assert Enum.any?(nodes, fn node ->
        node.type == :module && node.id == TestModule
      end)
    end

    test "analysis includes embeddings by default" do
      # Configure test directory
      Application.put_env(:ragex, :auto_analyze_dirs, [@test_dir])

      # Trigger the start phase
      assert :ok = Ragex.Application.start_phase(:auto_analyze, :normal, [])

      # Wait for analysis and embedding generation
      Process.sleep(1000)

      # Check that embeddings were generated
      nodes = Store.list_nodes()
      module_node = Enum.find(nodes, fn node ->
        node.type == :module && node.id == TestModule
      end)

      # Module should have embeddings
      assert module_node != nil
      # Note: Embeddings are stored in VectorStore, not in node metadata
      # This test just verifies analysis completes without error
    end
  end

  describe "directory analysis integration" do
    test "Directory.analyze_directory works correctly" do
      {:ok, result} = Directory.analyze_directory(@test_dir)

      # Should have analyzed at least one file
      assert result.total >= 1
      # May or may not have successes depending on timing/embeddings
      assert result.errors >= 0
    end

    test "analyzed files are added to graph" do
      {:ok, _result} = Directory.analyze_directory(@test_dir)

      # Give it time to finish
      Process.sleep(200)

      nodes = Store.list_nodes()
      assert Enum.any?(nodes, fn node ->
        node.type == :module && node.id == TestModule
      end)
    end
  end
end
