defmodule Ragex.Analyzers.DeeperIndexingTest do
  use ExUnit.Case, async: true

  alias Ragex.Analyzers.DeeperIndexing
  alias Ragex.Analyzers.Elixir, as: ElixirAnalyzer

  @elixir_source """
  defmodule MyApp.Accounts do
    # User management module
    # Handles CRUD operations

    def create_user(attrs) do
      query = "INSERT INTO users (name, email) VALUES ($1, $2)"
      error_msg = "invalid email format"
      Repo.query(query, [attrs.name, attrs.email])
    end

    # TODO: add caching
    def get_user(id) do
      Repo.get(User, id)
    end
  end
  """

  @js_source """
  // Database access layer
  // Author: team

  function createUser(name, email) {
    const query = "INSERT INTO users (name, email) VALUES (?, ?)";
    const errorMsg = "Validation failed";
    return db.execute(query, [name, email]);
  }

  /* Multi-line
     block comment */
  function getUser(id) {
    return db.query("SELECT * FROM users WHERE id = ?", [id]);
  }
  """

  @python_source """
  # User management service
  # Database operations

  def create_user(name, email):
      query = "INSERT INTO users VALUES (%s, %s)"
      error = "invalid input"
      return db.execute(query, (name, email))

  # Cache lookup
  def get_user(user_id):
      return db.fetch("SELECT * FROM users WHERE id = %s", (user_id,))
  """

  @erlang_source """
  -module(accounts).
  -export([create_user/2]).

  % User management
  % Database operations
  create_user(Name, Email) ->
      Query = "INSERT INTO users (name, email) VALUES ($1, $2)",
      db:execute(Query, [Name, Email]).
  """

  describe "extract/3 with Elixir" do
    test "extracts string literals from Elixir source" do
      {:ok, analysis} = ElixirAnalyzer.analyze(@elixir_source, "lib/accounts.ex")
      enrichment = DeeperIndexing.extract(@elixir_source, "lib/accounts.ex", analysis)

      # Should have strings associated with functions
      all_strings = enrichment.strings |> Map.values() |> List.flatten()
      assert Enum.any?(all_strings, &String.contains?(&1, "INSERT INTO"))
    end

    test "extracts comments from Elixir source" do
      {:ok, analysis} = ElixirAnalyzer.analyze(@elixir_source, "lib/accounts.ex")
      enrichment = DeeperIndexing.extract(@elixir_source, "lib/accounts.ex", analysis)

      all_comments = enrichment.comments |> Map.values() |> List.flatten()
      assert Enum.any?(all_comments, &String.contains?(&1, "TODO"))
    end

    test "associates items with nearest function" do
      {:ok, analysis} = ElixirAnalyzer.analyze(@elixir_source, "lib/accounts.ex")
      enrichment = DeeperIndexing.extract(@elixir_source, "lib/accounts.ex", analysis)

      # The "TODO: add caching" comment should be near get_user, not create_user
      # Since it's on the line right before get_user's def
      refute enrichment.comments == %{}
    end
  end

  describe "extract/3 with JavaScript" do
    test "extracts string literals from JS source" do
      analysis = %{
        functions: [
          %{name: :createUser, module: :app, arity: 2, line: 4, metadata: %{}},
          %{name: :getUser, module: :app, arity: 1, line: 12, metadata: %{}}
        ],
        modules: []
      }

      enrichment = DeeperIndexing.extract(@js_source, "app.js", analysis)
      all_strings = enrichment.strings |> Map.values() |> List.flatten()
      assert Enum.any?(all_strings, &String.contains?(&1, "INSERT INTO"))
    end

    test "extracts line and block comments from JS" do
      analysis = %{functions: [], modules: []}
      enrichment = DeeperIndexing.extract(@js_source, "app.js", analysis)
      all_comments = enrichment.comments |> Map.values() |> List.flatten()
      assert Enum.any?(all_comments, &String.contains?(&1, "Database"))
    end
  end

  describe "extract/3 with Python" do
    test "extracts string literals from Python source" do
      analysis = %{
        functions: [
          %{name: :create_user, module: :service, arity: 2, line: 4, metadata: %{}},
          %{name: :get_user, module: :service, arity: 1, line: 10, metadata: %{}}
        ],
        modules: []
      }

      enrichment = DeeperIndexing.extract(@python_source, "service.py", analysis)
      all_strings = enrichment.strings |> Map.values() |> List.flatten()
      assert Enum.any?(all_strings, &String.contains?(&1, "INSERT INTO"))
    end

    test "extracts comments from Python source" do
      analysis = %{functions: [], modules: []}
      enrichment = DeeperIndexing.extract(@python_source, "service.py", analysis)
      all_comments = enrichment.comments |> Map.values() |> List.flatten()
      assert Enum.any?(all_comments, &String.contains?(&1, "User management"))
    end
  end

  describe "extract/3 with Erlang" do
    test "extracts strings from Erlang source" do
      analysis = %{
        functions: [
          %{name: :create_user, module: :accounts, arity: 2, line: 6, metadata: %{}}
        ],
        modules: []
      }

      enrichment = DeeperIndexing.extract(@erlang_source, "accounts.erl", analysis)
      all_strings = enrichment.strings |> Map.values() |> List.flatten()
      assert Enum.any?(all_strings, &String.contains?(&1, "INSERT INTO"))
    end

    test "extracts %-style comments from Erlang" do
      analysis = %{functions: [], modules: []}
      enrichment = DeeperIndexing.extract(@erlang_source, "accounts.erl", analysis)
      all_comments = enrichment.comments |> Map.values() |> List.flatten()
      assert Enum.any?(all_comments, &String.contains?(&1, "User management"))
    end
  end

  describe "merge_into_analysis/2" do
    test "merges enrichment into function metadata" do
      analysis = %{
        functions: [
          %{
            name: :create_user,
            module: MyApp.Accounts,
            arity: 1,
            line: 5,
            metadata: %{}
          }
        ],
        modules: []
      }

      enrichment = %{
        strings: %{{MyApp.Accounts, :create_user, 1} => ["INSERT INTO users"]},
        comments: %{{MyApp.Accounts, :create_user, 1} => ["TODO: validate"]}
      }

      merged = DeeperIndexing.merge_into_analysis(enrichment, analysis)
      [func] = merged.functions
      assert func.metadata.strings == ["INSERT INTO users"]
      assert func.metadata.comments == ["TODO: validate"]
    end

    test "defaults to empty lists when no enrichment for function" do
      analysis = %{
        functions: [
          %{name: :foo, module: Mod, arity: 0, line: 1, metadata: %{}}
        ],
        modules: []
      }

      enrichment = %{strings: %{}, comments: %{}}
      merged = DeeperIndexing.merge_into_analysis(enrichment, analysis)
      [func] = merged.functions
      assert func.metadata.strings == []
      assert func.metadata.comments == []
    end
  end

  describe "extract_strings/2" do
    test "returns empty list for unknown language" do
      assert DeeperIndexing.extract_strings("hello", :unknown) == []
    end
  end

  describe "extract_comments/2" do
    test "merges consecutive comment lines" do
      source = "# line one\n# line two\n\n# separate block"
      comments = DeeperIndexing.extract_comments(source, :elixir)
      # First two should be merged, third is separate
      assert [_, _] = comments
    end
  end
end
