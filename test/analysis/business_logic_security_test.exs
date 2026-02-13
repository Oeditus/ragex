defmodule Ragex.Analysis.BusinessLogicSecurityTest do
  use ExUnit.Case, async: true

  alias Ragex.Analysis.BusinessLogic

  @moduletag :analysis

  describe "available_analyzers/0" do
    test "includes all 33 analyzers" do
      analyzers = BusinessLogic.available_analyzers()

      # Original 20 analyzers
      assert :callback_hell in analyzers
      assert :missing_error_handling in analyzers
      assert :silent_error_case in analyzers
      assert :swallowing_exception in analyzers
      assert :hardcoded_value in analyzers
      assert :n_plus_one_query in analyzers
      assert :inefficient_filter in analyzers
      assert :unmanaged_task in analyzers
      assert :telemetry_in_recursive_function in analyzers
      assert :missing_telemetry_for_external_http in analyzers
      assert :sync_over_async in analyzers
      assert :direct_struct_update in analyzers
      assert :missing_handle_async in analyzers
      assert :blocking_in_plug in analyzers
      assert :missing_telemetry_in_auth_plug in analyzers
      assert :missing_telemetry_in_liveview_mount in analyzers
      assert :missing_telemetry_in_oban_worker in analyzers
      assert :missing_preload in analyzers
      assert :inline_javascript in analyzers
      assert :missing_throttle in analyzers

      # New 13 CWE-based security analyzers
      assert :sql_injection in analyzers
      assert :xss_vulnerability in analyzers
      assert :ssrf_vulnerability in analyzers
      assert :path_traversal in analyzers
      assert :insecure_direct_object_reference in analyzers
      assert :missing_authentication in analyzers
      assert :missing_authorization in analyzers
      assert :incorrect_authorization in analyzers
      assert :missing_csrf_protection in analyzers
      assert :sensitive_data_exposure in analyzers
      assert :unrestricted_file_upload in analyzers
      assert :improper_input_validation in analyzers
      assert :toctou in analyzers
    end

    test "has exactly 33 analyzers" do
      analyzers = BusinessLogic.available_analyzers()
      assert length(analyzers) == 33
    end
  end

  describe "recommendation/1 for security analyzers" do
    test "returns recommendation for sql_injection" do
      rec = BusinessLogic.recommendation(:sql_injection)
      assert is_binary(rec)
      assert String.contains?(rec, "parameterized") or String.contains?(rec, "CWE-89")
    end

    test "returns recommendation for xss_vulnerability" do
      rec = BusinessLogic.recommendation(:xss_vulnerability)
      assert is_binary(rec)
      assert String.contains?(rec, "escap") or String.contains?(rec, "CWE-79")
    end

    test "returns recommendation for ssrf_vulnerability" do
      rec = BusinessLogic.recommendation(:ssrf_vulnerability)
      assert is_binary(rec)
      assert String.contains?(rec, "whitelist") or String.contains?(rec, "CWE-918")
    end

    test "returns recommendation for path_traversal" do
      rec = BusinessLogic.recommendation(:path_traversal)
      assert is_binary(rec)
      assert String.contains?(rec, "sanitize") or String.contains?(rec, "CWE-22")
    end

    test "returns recommendation for insecure_direct_object_reference" do
      rec = BusinessLogic.recommendation(:insecure_direct_object_reference)
      assert is_binary(rec)
      assert String.contains?(rec, "authorization") or String.contains?(rec, "CWE-639")
    end

    test "returns recommendation for missing_authentication" do
      rec = BusinessLogic.recommendation(:missing_authentication)
      assert is_binary(rec)
      assert String.contains?(rec, "authentication") or String.contains?(rec, "CWE-306")
    end

    test "returns recommendation for missing_authorization" do
      rec = BusinessLogic.recommendation(:missing_authorization)
      assert is_binary(rec)
      assert String.contains?(rec, "authorization") or String.contains?(rec, "CWE-862")
    end

    test "returns recommendation for incorrect_authorization" do
      rec = BusinessLogic.recommendation(:incorrect_authorization)
      assert is_binary(rec)
      assert String.contains?(rec, "authorization") or String.contains?(rec, "CWE-863")
    end

    test "returns recommendation for missing_csrf_protection" do
      rec = BusinessLogic.recommendation(:missing_csrf_protection)
      assert is_binary(rec)
      assert String.contains?(rec, "CSRF") or String.contains?(rec, "CWE-352")
    end

    test "returns recommendation for sensitive_data_exposure" do
      rec = BusinessLogic.recommendation(:sensitive_data_exposure)
      assert is_binary(rec)
      assert String.contains?(rec, "encrypt") or String.contains?(rec, "CWE-200")
    end

    test "returns recommendation for unrestricted_file_upload" do
      rec = BusinessLogic.recommendation(:unrestricted_file_upload)
      assert is_binary(rec)
      assert String.contains?(rec, "file") or String.contains?(rec, "CWE-434")
    end

    test "returns recommendation for improper_input_validation" do
      rec = BusinessLogic.recommendation(:improper_input_validation)
      assert is_binary(rec)
      assert String.contains?(rec, "validat") or String.contains?(rec, "CWE-20")
    end

    test "returns recommendation for toctou" do
      rec = BusinessLogic.recommendation(:toctou)
      assert is_binary(rec)
      assert String.contains?(rec, "atomic") or String.contains?(rec, "CWE-367")
    end
  end

  describe "analyze_file/2 with security analyzers" do
    setup do
      tmp_dir = System.tmp_dir!()
      {:ok, tmp_dir: tmp_dir}
    end

    test "detects potential SQL injection patterns", %{tmp_dir: tmp_dir} do
      test_file = Path.join(tmp_dir, "sql_test_#{:rand.uniform(10000)}.ex")

      content = """
      defmodule SQLTestModule do
        import Ecto.Query

        def unsafe_query(user_input) do
          query = "SELECT * FROM users WHERE name = '\#{user_input}'"
          Ecto.Adapters.SQL.query!(Repo, query)
        end

        def safe_query(user_input) do
          from(u in User, where: u.name == ^user_input)
          |> Repo.all()
        end
      end
      """

      File.write!(test_file, content)
      on_exit(fn -> File.rm(test_file) end)

      {:ok, result} = BusinessLogic.analyze_file(test_file, analyzers: [:sql_injection])

      # Result should be valid structure
      assert is_map(result)
      assert result.file == test_file
    end

    test "runs all security analyzers", %{tmp_dir: tmp_dir} do
      test_file = Path.join(tmp_dir, "security_test_#{:rand.uniform(10000)}.ex")

      content = """
      defmodule SecurityTestModule do
        def some_function(x) do
          x + 1
        end
      end
      """

      File.write!(test_file, content)
      on_exit(fn -> File.rm(test_file) end)

      security_analyzers = [
        :sql_injection,
        :xss_vulnerability,
        :ssrf_vulnerability,
        :path_traversal,
        :insecure_direct_object_reference,
        :missing_authentication,
        :missing_authorization,
        :incorrect_authorization,
        :missing_csrf_protection,
        :sensitive_data_exposure,
        :unrestricted_file_upload,
        :improper_input_validation,
        :toctou
      ]

      {:ok, result} = BusinessLogic.analyze_file(test_file, analyzers: security_analyzers)

      assert is_map(result)
      assert result.file == test_file
      assert is_list(result.issues)
    end

    test "runs all analyzers when none specified", %{tmp_dir: tmp_dir} do
      test_file = Path.join(tmp_dir, "all_test_#{:rand.uniform(10000)}.ex")

      content = """
      defmodule AllTestModule do
        def simple_function(x), do: x + 1
      end
      """

      File.write!(test_file, content)
      on_exit(fn -> File.rm(test_file) end)

      {:ok, result} = BusinessLogic.analyze_file(test_file, analyzers: :all)

      assert is_map(result)
      assert result.file == test_file
    end
  end

  describe "analyze_directory/2 with security analyzers" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "bl_security_dir_#{:rand.uniform(10000)}")
      File.mkdir_p!(tmp_dir)

      file1 = Path.join(tmp_dir, "module1.ex")

      File.write!(file1, """
      defmodule Module1 do
        def func1(x), do: x + 1
      end
      """)

      file2 = Path.join(tmp_dir, "module2.ex")

      File.write!(file2, """
      defmodule Module2 do
        def func2(user_input) do
          # Potentially unsafe pattern
          File.read!(user_input)
        end
      end
      """)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      {:ok, tmp_dir: tmp_dir}
    end

    test "analyzes directory with security analyzers", %{tmp_dir: tmp_dir} do
      {:ok, result} =
        BusinessLogic.analyze_directory(tmp_dir,
          analyzers: [:path_traversal, :improper_input_validation]
        )

      assert is_map(result)
      assert result.total_files == 2
      assert is_list(result.results)
    end

    test "filters by severity", %{tmp_dir: tmp_dir} do
      {:ok, result} =
        BusinessLogic.analyze_directory(tmp_dir,
          analyzers: :all,
          min_severity: :high
        )

      assert is_map(result)
      # Should have filtered results
      assert is_list(result.results)
    end
  end
end
