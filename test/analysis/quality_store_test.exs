defmodule Ragex.Analysis.QualityStoreTest do
  use ExUnit.Case, async: false

  alias Ragex.Analysis.QualityStore
  alias Ragex.Graph.Store

  @moduletag :analysis

  setup do
    # Clear all metrics before each test
    QualityStore.clear_all()
    Store.sync()
    :ok
  end

  describe "store_metrics/1" do
    test "stores quality metrics in graph" do
      result = sample_result("lib/module1.ex")

      assert :ok = QualityStore.store_metrics(result)
      Store.sync()
      assert QualityStore.count() == 1
    end

    test "updates existing metrics for same file" do
      result1 = sample_result("lib/module1.ex", cyclomatic: 5)
      result2 = sample_result("lib/module1.ex", cyclomatic: 10)

      :ok = QualityStore.store_metrics(result1)
      :ok = QualityStore.store_metrics(result2)
      Store.sync()

      # Should still be 1 file (updated, not duplicated)
      assert QualityStore.count() == 1

      {:ok, metrics} = QualityStore.get_metrics("lib/module1.ex")
      assert metrics.cyclomatic == 10
    end

    test "stores multiple files" do
      result1 = sample_result("lib/module1.ex")
      result2 = sample_result("lib/module2.ex")
      result3 = sample_result("test/module_test.exs")

      :ok = QualityStore.store_metrics(result1)
      :ok = QualityStore.store_metrics(result2)
      :ok = QualityStore.store_metrics(result3)
      Store.sync()

      assert QualityStore.count() == 3
    end
  end

  describe "get_metrics/1" do
    test "retrieves stored metrics" do
      result = sample_result("lib/module1.ex", cyclomatic: 7, cognitive: 5)
      :ok = QualityStore.store_metrics(result)
      Store.sync()

      assert {:ok, metrics} = QualityStore.get_metrics("lib/module1.ex")
      assert metrics.path == "lib/module1.ex"
      assert metrics.cyclomatic == 7
      assert metrics.cognitive == 5
      assert metrics.language == :elixir
    end

    test "returns error for non-existent file" do
      assert {:error, :not_found} = QualityStore.get_metrics("nonexistent.ex")
    end
  end

  describe "find_by_threshold/3" do
    setup do
      :ok = QualityStore.store_metrics(sample_result("lib/simple.ex", cyclomatic: 2))
      :ok = QualityStore.store_metrics(sample_result("lib/medium.ex", cyclomatic: 8))
      :ok = QualityStore.store_metrics(sample_result("lib/complex.ex", cyclomatic: 15))
      Store.sync()
      :ok
    end

    test "finds files exceeding threshold" do
      files = QualityStore.find_by_threshold(:cyclomatic, 10)

      assert length(files) == 1
      assert "lib/complex.ex" in files
    end

    test "finds files with >= operator" do
      files = QualityStore.find_by_threshold(:cyclomatic, 8, operator: :gte)

      assert length(files) == 2
      assert "lib/medium.ex" in files
      assert "lib/complex.ex" in files
    end

    test "finds files with < operator" do
      files = QualityStore.find_by_threshold(:cyclomatic, 5, operator: :lt)

      assert length(files) == 1
      assert "lib/simple.ex" in files
    end

    test "finds files with exact match" do
      files = QualityStore.find_by_threshold(:cyclomatic, 8, operator: :eq)

      assert length(files) == 1
      assert "lib/medium.ex" in files
    end

    test "works with cognitive complexity" do
      :ok = QualityStore.store_metrics(sample_result("lib/cognitive.ex", cognitive: 20))
      Store.sync()

      files = QualityStore.find_by_threshold(:cognitive, 15)

      assert "lib/cognitive.ex" in files
    end
  end

  describe "find_with_warnings/0" do
    test "finds files with warnings" do
      :ok =
        QualityStore.store_metrics(
          sample_result("lib/warned.ex", warnings: ["Complexity too high"])
        )

      Store.sync()

      :ok = QualityStore.store_metrics(sample_result("lib/clean.ex", warnings: []))
      Store.sync()

      result = QualityStore.find_with_warnings()

      assert length(result) == 1
      assert {"lib/warned.ex", ["Complexity too high"]} in result
    end

    test "returns empty list when no warnings" do
      :ok = QualityStore.store_metrics(sample_result("lib/clean.ex"))
      Store.sync()

      assert QualityStore.find_with_warnings() == []
    end
  end

  describe "find_impure/0" do
    test "finds impure files" do
      :ok =
        QualityStore.store_metrics(
          sample_result("lib/impure.ex", purity: %{pure?: false, effects: [:io]})
        )

      Store.sync()

      :ok = QualityStore.store_metrics(sample_result("lib/pure.ex", purity: %{pure?: true}))
      Store.sync()

      impure_files = QualityStore.find_impure()

      assert length(impure_files) == 1
      assert "lib/impure.ex" in impure_files
    end
  end

  describe "project_stats/0" do
    test "returns statistics for analyzed files" do
      :ok = QualityStore.store_metrics(sample_result("lib/file1.ex", cyclomatic: 5))
      :ok = QualityStore.store_metrics(sample_result("lib/file2.ex", cyclomatic: 10))
      :ok = QualityStore.store_metrics(sample_result("lib/file3.ex", cyclomatic: 15))
      Store.sync()

      stats = QualityStore.project_stats()

      assert stats.total_files == 3
      assert stats.avg_cyclomatic == 10.0
      assert stats.max_cyclomatic == 15
      assert stats.min_cyclomatic == 5
    end

    test "handles empty project" do
      stats = QualityStore.project_stats()

      assert stats.total_files == 0
      assert stats.avg_cyclomatic == 0.0
    end

    test "counts warnings and impure files" do
      :ok =
        QualityStore.store_metrics(sample_result("lib/file1.ex", warnings: ["High complexity"]))

      Store.sync()

      :ok =
        QualityStore.store_metrics(
          sample_result("lib/file2.ex", purity: %{pure?: false, effects: [:io]})
        )

      Store.sync()

      :ok = QualityStore.store_metrics(sample_result("lib/file3.ex"))
      Store.sync()

      stats = QualityStore.project_stats()

      assert stats.files_with_warnings == 1
      assert stats.impure_files == 1
    end

    test "groups by language" do
      :ok = QualityStore.store_metrics(sample_result("lib/file1.ex", language: :elixir))
      :ok = QualityStore.store_metrics(sample_result("lib/file2.ex", language: :elixir))
      :ok = QualityStore.store_metrics(sample_result("src/file.erl", language: :erlang))
      Store.sync()

      stats = QualityStore.project_stats()

      assert stats.languages[:elixir] == 2
      assert stats.languages[:erlang] == 1
    end
  end

  describe "stats_by_language/0" do
    test "returns stats grouped by language" do
      :ok =
        QualityStore.store_metrics(
          sample_result("lib/file1.ex", language: :elixir, cyclomatic: 5)
        )

      Store.sync()

      :ok =
        QualityStore.store_metrics(
          sample_result("lib/file2.ex", language: :elixir, cyclomatic: 10)
        )

      Store.sync()

      :ok =
        QualityStore.store_metrics(
          sample_result("src/file.erl", language: :erlang, cyclomatic: 3)
        )

      Store.sync()

      by_lang = QualityStore.stats_by_language()

      assert by_lang[:elixir].total_files == 2
      assert by_lang[:elixir].avg_cyclomatic == 7.5

      assert by_lang[:erlang].total_files == 1
      assert by_lang[:erlang].avg_cyclomatic == 3.0
    end
  end

  describe "most_complex/1" do
    test "returns most complex files by cyclomatic" do
      :ok = QualityStore.store_metrics(sample_result("lib/simple.ex", cyclomatic: 2))
      :ok = QualityStore.store_metrics(sample_result("lib/medium.ex", cyclomatic: 8))
      :ok = QualityStore.store_metrics(sample_result("lib/complex.ex", cyclomatic: 15))
      Store.sync()

      result = QualityStore.most_complex(metric: :cyclomatic, limit: 2)

      assert length(result) == 2
      assert {"lib/complex.ex", 15} = List.first(result)
      assert {"lib/medium.ex", 8} = List.last(result)
    end

    test "works with cognitive complexity" do
      :ok = QualityStore.store_metrics(sample_result("lib/file1.ex", cognitive: 10))
      :ok = QualityStore.store_metrics(sample_result("lib/file2.ex", cognitive: 20))
      Store.sync()

      result = QualityStore.most_complex(metric: :cognitive, limit: 1)

      assert [{"lib/file2.ex", 20}] = result
    end

    test "respects limit parameter" do
      for i <- 1..10 do
        :ok = QualityStore.store_metrics(sample_result("lib/file#{i}.ex", cyclomatic: i))
      end

      Store.sync()

      result = QualityStore.most_complex(limit: 3)

      assert length(result) == 3
    end
  end

  describe "clear_all/0" do
    test "removes all quality metrics" do
      :ok = QualityStore.store_metrics(sample_result("lib/file1.ex"))
      :ok = QualityStore.store_metrics(sample_result("lib/file2.ex"))
      Store.sync()

      assert QualityStore.count() == 2

      :ok = QualityStore.clear_all()
      Store.sync()

      assert QualityStore.count() == 0
    end
  end

  describe "count/0" do
    test "returns number of stored metrics" do
      assert QualityStore.count() == 0

      :ok = QualityStore.store_metrics(sample_result("lib/file1.ex"))
      Store.sync()
      assert QualityStore.count() == 1

      :ok = QualityStore.store_metrics(sample_result("lib/file2.ex"))
      Store.sync()
      assert QualityStore.count() == 2
    end
  end

  # Helper functions

  defp sample_result(path, opts \\ []) do
    cyclomatic = Keyword.get(opts, :cyclomatic, 5)
    cognitive = Keyword.get(opts, :cognitive, 3)
    language = Keyword.get(opts, :language, :elixir)
    warnings = Keyword.get(opts, :warnings, [])
    purity = Keyword.get(opts, :purity, %{pure?: true, effects: []})

    %{
      path: path,
      language: language,
      complexity: %{
        cyclomatic: cyclomatic,
        cognitive: cognitive,
        max_nesting: 2,
        halstead: %{volume: 100.0},
        loc: %{physical: 50, logical: 30},
        function_metrics: %{statements: 10}
      },
      purity: purity,
      warnings: warnings,
      timestamp: DateTime.utc_now()
    }
  end
end
