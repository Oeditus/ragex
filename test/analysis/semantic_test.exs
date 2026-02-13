defmodule Ragex.Analysis.SemanticTest do
  use ExUnit.Case, async: true

  alias Ragex.Analysis.Semantic

  @moduletag :analysis

  describe "domains/0" do
    test "returns all supported semantic domains" do
      domains = Semantic.domains()

      assert :db in domains
      assert :http in domains
      assert :auth in domains
      assert :cache in domains
      assert :queue in domains
      assert :file in domains
      assert :external_api in domains
    end
  end

  describe "parse_file/2" do
    setup do
      tmp_dir = System.tmp_dir!()
      test_file = Path.join(tmp_dir, "semantic_test_#{:rand.uniform(10000)}.ex")

      content = """
      defmodule SemanticTestModule do
        alias MyApp.Repo

        def get_user(id) do
          Repo.get(User, id)
        end

        def create_user(attrs) do
          %User{}
          |> User.changeset(attrs)
          |> Repo.insert()
        end

        def make_request(url) do
          HTTPoison.get(url)
        end

        def authenticate(username, password) do
          # Simulated auth check
          if valid_credentials?(username, password) do
            {:ok, generate_token()}
          else
            {:error, :unauthorized}
          end
        end

        defp valid_credentials?(_, _), do: true
        defp generate_token, do: "token"
      end
      """

      File.write!(test_file, content)

      on_exit(fn -> File.rm(test_file) end)

      {:ok, test_file: test_file}
    end

    test "parses file with semantic enrichment", %{test_file: test_file} do
      assert {:ok, result} = Semantic.parse_file(test_file)

      # parse_file returns a Metastatic.Document struct
      assert is_struct(result) or is_map(result)
      assert result.language == :elixir
      assert result.ast != nil
    end

    test "handles non-existent file" do
      assert {:error, _reason} = Semantic.parse_file("nonexistent.ex")
    end
  end

  describe "analyze_file/2" do
    setup do
      tmp_dir = System.tmp_dir!()
      test_file = Path.join(tmp_dir, "semantic_analyze_#{:rand.uniform(10000)}.ex")

      content = """
      defmodule DatabaseModule do
        alias MyApp.Repo

        def get_item(id) do
          Repo.get(Item, id)
        end

        def list_items do
          Repo.all(Item)
        end

        def create_item(attrs) do
          %Item{}
          |> Item.changeset(attrs)
          |> Repo.insert()
        end

        def update_item(item, attrs) do
          item
          |> Item.changeset(attrs)
          |> Repo.update()
        end

        def delete_item(item) do
          Repo.delete(item)
        end
      end
      """

      File.write!(test_file, content)

      on_exit(fn -> File.rm(test_file) end)

      {:ok, test_file: test_file}
    end

    test "extracts semantic operations from file", %{test_file: test_file} do
      assert {:ok, result} = Semantic.analyze_file(test_file)

      assert is_map(result)
      # semantic_context has :file key, not :path
      assert result.file == test_file
      assert is_map(result.domains)
    end

    test "context has expected structure", %{test_file: test_file} do
      {:ok, result} = Semantic.analyze_file(test_file)

      assert result.language == :elixir
      assert is_binary(result.summary)
      assert is_boolean(result.security_relevant)
      assert is_integer(result.operation_count)
      assert %DateTime{} = result.timestamp
    end
  end

  describe "analyze_directory/2" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "semantic_dir_#{:rand.uniform(10000)}")
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
        alias MyApp.Repo
        def get_data(id), do: Repo.get(Data, id)
      end
      """)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      {:ok, tmp_dir: tmp_dir}
    end

    test "analyzes directory for semantic operations", %{tmp_dir: tmp_dir} do
      assert {:ok, result} = Semantic.analyze_directory(tmp_dir)

      assert is_map(result)
      assert result.path == tmp_dir
      assert is_list(result.operations)
      assert is_list(result.files)
      assert length(result.files) == 2
      assert is_integer(result.total_operations)
      assert is_map(result.by_domain)
    end

    test "respects recursive option", %{tmp_dir: tmp_dir} do
      sub_dir = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(sub_dir)

      sub_file = Path.join(sub_dir, "sub_module.ex")

      File.write!(sub_file, """
      defmodule SubModule do
        def sub_func, do: :ok
      end
      """)

      # With recursive
      {:ok, result_recursive} = Semantic.analyze_directory(tmp_dir, recursive: true)
      assert length(result_recursive.files) == 3

      # Without recursive
      {:ok, result_non_recursive} = Semantic.analyze_directory(tmp_dir, recursive: false)
      assert length(result_non_recursive.files) == 2
    end
  end

  describe "extract_operations/2" do
    setup do
      tmp_dir = System.tmp_dir!()
      test_file = Path.join(tmp_dir, "extract_ops_test_#{:rand.uniform(10000)}.ex")

      content = """
      defmodule ExtractOpsTest do
        alias MyApp.Repo
        def get_data(id), do: Repo.get(Data, id)
      end
      """

      File.write!(test_file, content)
      on_exit(fn -> File.rm(test_file) end)

      {:ok, test_file: test_file}
    end

    test "extracts operations from parsed document", %{test_file: test_file} do
      {:ok, doc} = Semantic.parse_file(test_file)

      # extract_operations requires a Document struct
      assert {:ok, operations} = Semantic.extract_operations(doc)
      assert is_list(operations)
    end

    test "filters by domain", %{test_file: test_file} do
      {:ok, doc} = Semantic.parse_file(test_file)

      assert {:ok, db_ops} = Semantic.extract_operations(doc, domain: :db)
      assert is_list(db_ops)
    end
  end

  describe "security_operations/1" do
    test "returns empty list for empty input" do
      result = Semantic.security_operations([])
      assert result == []
    end

    test "identifies write operations as security-relevant" do
      ops = [
        %{domain: :db, operation: :read, target: :user, async: false, framework: nil},
        %{domain: :db, operation: :write, target: :user, async: false, framework: nil},
        %{domain: :db, operation: :delete, target: :user, async: false, framework: nil}
      ]

      result = Semantic.security_operations(ops)

      # Write and delete operations should be considered security-relevant
      assert length(result) >= 1
    end

    test "identifies auth operations as security-relevant" do
      ops = [
        %{domain: :auth, operation: :authenticate, target: :user, async: false, framework: nil},
        %{domain: :auth, operation: :authorize, target: :resource, async: false, framework: nil}
      ]

      result = Semantic.security_operations(ops)

      # All auth operations should be security-relevant
      assert length(result) == 2
    end
  end

  describe "operations_summary/1" do
    test "summarizes operations by domain" do
      ops = [
        %{domain: :db, operation: :read, target: :user, async: false, framework: nil},
        %{domain: :db, operation: :write, target: :user, async: false, framework: nil},
        %{domain: :http, operation: :get, target: :api, async: false, framework: nil}
      ]

      summary = Semantic.operations_summary(ops)

      assert is_map(summary)
      assert Map.get(summary, :db) == 2
      assert Map.get(summary, :http) == 1
    end

    test "returns map with zero counts for empty input" do
      summary = Semantic.operations_summary([])

      # The implementation initializes all domains with 0
      assert is_map(summary)
      assert Map.get(summary, :db) == 0
      assert Map.get(summary, :http) == 0
    end
  end

  describe "describe_operations/1" do
    test "generates human-readable descriptions" do
      ops = [
        %{domain: :db, operation: :read, target: :user, async: false, framework: :ecto}
      ]

      description = Semantic.describe_operations(ops)

      # describe_operations returns a single string, not a list
      assert is_binary(description)
      assert String.contains?(description, "database")
    end

    test "returns descriptive string for empty input" do
      description = Semantic.describe_operations([])
      assert description == "No semantic operations detected"
    end
  end
end
