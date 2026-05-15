defmodule Ragex.Search.KeywordsTest do
  use ExUnit.Case, async: true

  alias Ragex.Search.Keywords

  describe "extract/1" do
    test "extracts keywords from function name" do
      func = %{
        name: :create_user,
        module: MyApp.Accounts,
        arity: 2,
        doc: nil,
        spec: nil,
        metadata: %{}
      }

      kw = Keywords.extract(func)
      assert Map.has_key?(kw, "create")
      assert Map.has_key?(kw, "user")
    end

    test "doc keywords get highest boost (1.5)" do
      func = %{
        name: :foo,
        module: Mod,
        arity: 0,
        doc: "Creates a new database record",
        spec: nil,
        metadata: %{}
      }

      kw = Keywords.extract(func)
      assert kw["creates"] == 1.5
      assert kw["database"] == 1.5
      assert kw["record"] == 1.5
    end

    test "string keywords get 0.8 boost" do
      func = %{
        name: :foo,
        module: Mod,
        arity: 0,
        doc: nil,
        spec: nil,
        metadata: %{strings: ["INSERT INTO users"]}
      }

      kw = Keywords.extract(func)
      assert kw["insert"] == 0.8
      assert kw["into"] == 0.8
      assert kw["users"] == 0.8
    end

    test "comment keywords get 0.6 boost" do
      func = %{
        name: :foo,
        module: Mod,
        arity: 0,
        doc: nil,
        spec: nil,
        metadata: %{comments: ["TODO refactor this"]}
      }

      kw = Keywords.extract(func)
      assert kw["todo"] == 0.6
      assert kw["refactor"] == 0.6
    end

    test "higher boost wins when keyword appears in multiple sources" do
      func = %{
        name: :create_user,
        module: Mod,
        arity: 0,
        doc: "Create a user",
        spec: nil,
        metadata: %{strings: ["user created"], comments: ["user stuff"]}
      }

      kw = Keywords.extract(func)
      # "user" from doc (1.5) > from name (1.0) > from strings (0.8)
      assert kw["user"] == 1.5
    end

    test "filters stop words" do
      func = %{
        name: :the_function,
        module: Mod,
        arity: 0,
        doc: "This is a test",
        spec: nil,
        metadata: %{}
      }

      kw = Keywords.extract(func)
      refute Map.has_key?(kw, "the")
      refute Map.has_key?(kw, "is")
    end

    test "filters short tokens" do
      func = %{
        name: :a,
        module: Mod,
        arity: 0,
        doc: "I do X",
        spec: nil,
        metadata: %{}
      }

      kw = Keywords.extract(func)
      refute Map.has_key?(kw, "a")
      refute Map.has_key?(kw, "x")
    end
  end

  describe "extract_module/1" do
    test "extracts keywords from module name and doc" do
      mod = %{name: MyApp.UserAccounts, doc: "Manages user accounts"}
      kw = Keywords.extract_module(mod)
      assert Map.has_key?(kw, "user")
      assert Map.has_key?(kw, "accounts")
      assert kw["manages"] == 1.5
    end
  end

  describe "tokenize_name/1" do
    test "splits snake_case" do
      assert Keywords.tokenize_name(:create_user) == ["create", "user"]
    end

    test "splits CamelCase" do
      assert Keywords.tokenize_name(MyApp.UserAccounts) == ["my", "app", "user", "accounts"]
    end

    test "handles binary input" do
      tokens = Keywords.tokenize_name("get_user_by_id")
      assert "get" in tokens
      assert "user" in tokens
      # "by" and "id" are filtered (stop word / too short)
    end
  end

  describe "tokenize_text/1" do
    test "extracts tokens from free text" do
      tokens = Keywords.tokenize_text("Creates a new database record")
      assert "creates" in tokens
      assert "database" in tokens
      assert "record" in tokens
    end

    test "handles nil input" do
      assert Keywords.tokenize_text(nil) == []
    end

    test "strips punctuation" do
      tokens = Keywords.tokenize_text("Hello, world! How's it?")
      assert "hello" in tokens
      assert "world" in tokens
    end
  end

  describe "relevance_boost/2" do
    test "returns 1.0 for empty keywords" do
      assert Keywords.relevance_boost(%{}, ["test"]) == 1.0
    end

    test "returns 1.0 for empty query terms" do
      assert Keywords.relevance_boost(%{"test" => 1.0}, []) == 1.0
    end

    test "boosts matching keywords" do
      keywords = %{"user" => 1.5, "create" => 1.0}
      boost = Keywords.relevance_boost(keywords, ["user", "create"])
      assert boost > 1.0
    end

    test "no boost for non-matching terms" do
      keywords = %{"user" => 1.5}
      boost = Keywords.relevance_boost(keywords, ["database"])
      assert boost == 1.0
    end
  end
end
