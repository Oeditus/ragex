defmodule Ragex.Analysis.Semantic do
  @moduledoc """
  Semantic code analysis using Metastatic's OpKind metadata system.

  This module provides access to semantic operation analysis, allowing
  extraction and analysis of code operations by domain (database, HTTP,
  authentication, caching, file I/O, etc.).

  ## OpKind Domains

  The following semantic domains are supported:

  - `:db` - Database operations (Ecto, Django ORM, ActiveRecord, Sequelize, etc.)
  - `:http` - HTTP client operations (HTTPoison, Req, requests, axios, etc.)
  - `:auth` - Authentication/authorization (Guardian, Pow, Devise, Passport, etc.)
  - `:cache` - Cache operations (Cachex, Redis, Memcached, etc.)
  - `:queue` - Message queue operations (Oban, Broadway, Celery, Sidekiq, etc.)
  - `:file` - File I/O operations (File, fs, shutil, etc.)
  - `:external_api` - External service calls (AWS, Stripe, Twilio, etc.)

  ## Usage

      alias Ragex.Analysis.Semantic

      # Parse file with semantic enrichment
      {:ok, doc} = Semantic.parse_file("lib/my_module.ex")

      # Extract all semantic operations
      {:ok, ops} = Semantic.extract_operations(doc)

      # Extract operations by domain
      {:ok, db_ops} = Semantic.extract_operations(doc, domain: :db)
      {:ok, http_ops} = Semantic.extract_operations(doc, domain: :http)

      # Analyze file for semantic context
      {:ok, context} = Semantic.analyze_file("lib/my_module.ex")

      # Get security-relevant operations
      {:ok, security_ops} = Semantic.security_operations(doc)

  ## Semantic Context

  The semantic context provides AI-friendly summaries of code operations:

      %{
        file: "lib/user_controller.ex",
        domains: %{
          db: [%{operation: :retrieve, target: "User", framework: :ecto, count: 3}],
          http: [],
          auth: [%{operation: :authenticate, framework: :guardian, count: 1}]
        },
        summary: "Controller with 3 DB reads, 1 auth check",
        security_relevant: true
      }
  """

  alias Metastatic.{Builder, Document}
  alias Metastatic.Semantic.{Enricher, OpKind}
  require Logger

  @type domain :: :db | :http | :auth | :cache | :queue | :file | :external_api

  @type operation :: %{
          domain: domain(),
          operation: atom(),
          target: String.t() | nil,
          framework: atom() | nil,
          async: boolean(),
          line: non_neg_integer() | nil
        }

  @type semantic_context :: %{
          file: String.t(),
          language: atom(),
          domains: %{domain() => [operation()]},
          summary: String.t(),
          security_relevant: boolean(),
          operation_count: non_neg_integer(),
          timestamp: DateTime.t()
        }

  @domains [:db, :http, :auth, :cache, :queue, :file, :external_api]

  @doc """
  Returns the list of supported semantic domains.

  ## Examples

      iex> Ragex.Analysis.Semantic.domains()
      [:db, :http, :auth, :cache, :queue, :file, :external_api]
  """
  @spec domains() :: [domain()]
  def domains, do: @domains

  @doc """
  Parses a file with semantic enrichment.

  This parses the source code to MetaAST and enriches function calls
  with OpKind semantic metadata.

  ## Options

  - `:language` - Explicit language (default: auto-detect)
  - `:enrich` - Whether to apply semantic enrichment (default: true)

  ## Examples

      {:ok, doc} = Semantic.parse_file("lib/my_module.ex")
  """
  @spec parse_file(String.t(), keyword()) :: {:ok, Document.t()} | {:error, term()}
  def parse_file(path, opts \\ []) do
    language = Keyword.get(opts, :language, detect_language(path))
    enrich = Keyword.get(opts, :enrich, true)

    with {:ok, content} <- File.read(path),
         {:ok, doc} <- Builder.from_source(content, language) do
      if enrich do
        enriched_ast = Enricher.enrich_tree(doc.ast, language)
        {:ok, %{doc | ast: enriched_ast}}
      else
        {:ok, doc}
      end
    else
      {:error, reason} = error ->
        Logger.warning("Failed to parse #{path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Extracts semantic operations from a document.

  ## Options

  - `:domain` - Filter by specific domain (default: all)

  ## Examples

      {:ok, all_ops} = Semantic.extract_operations(doc)
      {:ok, db_ops} = Semantic.extract_operations(doc, domain: :db)
  """
  @spec extract_operations(Document.t(), keyword()) :: {:ok, [operation()]} | {:error, term()}
  def extract_operations(%Document{ast: ast, language: language}, opts \\ []) do
    domain_filter = Keyword.get(opts, :domain)

    operations = extract_ops_from_ast(ast, language, [])

    filtered =
      if domain_filter do
        Enum.filter(operations, &(&1.domain == domain_filter))
      else
        operations
      end

    {:ok, filtered}
  rescue
    e ->
      {:error, {:extraction_failed, e}}
  end

  @doc """
  Analyzes a file and returns semantic context.

  Provides a structured summary of all semantic operations in the file,
  grouped by domain, with security relevance flagging.

  ## Examples

      {:ok, context} = Semantic.analyze_file("lib/user_controller.ex")
      context.security_relevant  # => true (has auth/db operations)
  """
  @spec analyze_file(String.t(), keyword()) :: {:ok, semantic_context()} | {:error, term()}
  def analyze_file(path, opts \\ []) do
    with {:ok, doc} <- parse_file(path, opts),
         {:ok, operations} <- extract_operations(doc) do
      context = build_context(path, doc.language, operations)
      {:ok, context}
    end
  end

  @doc """
  Analyzes multiple files in a directory for semantic context.

  ## Options

  - `:recursive` - Recursively analyze subdirectories (default: true)
  - `:parallel` - Use parallel processing (default: true)
  - `:max_concurrency` - Maximum concurrent analyses (default: System.schedulers_online())

  ## Examples

      {:ok, contexts} = Semantic.analyze_directory("lib/")
  """
  @type directory_result :: %{
          path: String.t(),
          files: [String.t()],
          operations: [operation()],
          total_operations: non_neg_integer(),
          by_domain: %{domain() => non_neg_integer()},
          security_relevant: boolean()
        }

  @spec analyze_directory(String.t(), keyword()) ::
          {:ok, directory_result()} | {:error, term()}
  def analyze_directory(path, opts \\ []) do
    recursive = Keyword.get(opts, :recursive, true)
    parallel = Keyword.get(opts, :parallel, true)
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())

    case find_source_files(path, recursive) do
      {:ok, []} ->
        {:ok,
         %{
           path: path,
           files: [],
           operations: [],
           total_operations: 0,
           by_domain: Map.new(@domains, fn d -> {d, 0} end),
           security_relevant: false
         }}

      {:ok, files} ->
        contexts =
          if parallel do
            analyze_files_parallel(files, opts, max_concurrency)
          else
            Enum.map(files, fn file ->
              case analyze_file(file, opts) do
                {:ok, context} -> context
                {:error, _} -> nil
              end
            end)
            |> Enum.reject(&is_nil/1)
          end

        # Aggregate all operations from all files
        all_operations =
          contexts
          |> Enum.flat_map(fn ctx ->
            ctx.domains
            |> Enum.flat_map(fn {domain, ops} ->
              Enum.map(ops, fn op ->
                %{
                  domain: domain,
                  operation: op.operation,
                  target: op.target,
                  framework: op.framework,
                  async: false,
                  line: nil
                }
              end)
            end)
          end)

        result = %{
          path: path,
          files: Enum.map(contexts, & &1.file),
          operations: all_operations,
          total_operations: length(all_operations),
          by_domain: operations_summary(all_operations),
          security_relevant: Enum.any?(contexts, & &1.security_relevant)
        }

        {:ok, result}

      {:error, reason} = error ->
        Logger.error("Failed to list directory #{path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Extracts or filters security-relevant operations.

  When given a `Document`, extracts security-relevant operations from it.
  When given a list of operations, filters to security-relevant ones.

  Returns operations from domains that are security-sensitive:
  - `:db` - Database operations (SQL injection, data access)
  - `:auth` - Authentication/authorization
  - `:file` - File operations (path traversal)
  - `:http` - HTTP operations (SSRF)
  - `:external_api` - External APIs

  Also includes operations with write/delete/modify actions.

  ## Examples

      # From document
      {:ok, security_ops} = Semantic.security_operations(doc)

      # From list
      security_ops = Semantic.security_operations(operations)
  """
  @spec security_operations(Document.t() | [operation()]) ::
          {:ok, [operation()]} | {:error, term()} | [operation()]
  def security_operations(%Document{} = doc) do
    with {:ok, all_ops} <- extract_operations(doc) do
      {:ok, security_operations(all_ops)}
    end
  end

  def security_operations(operations) when is_list(operations) do
    security_domains = [:db, :auth, :file, :http, :external_api]
    write_operations = [:write, :create, :update, :delete, :remove, :modify, :insert]

    Enum.filter(operations, fn op ->
      op.domain in security_domains or op.operation in write_operations
    end)
  end

  @doc """
  Returns a summary of operations by domain.

  ## Examples

      summary = Semantic.operations_summary(operations)
      # => %{db: 5, http: 2, auth: 1, cache: 0, queue: 0, file: 3, external_api: 0}
  """
  @spec operations_summary([operation()]) :: %{domain() => non_neg_integer()}
  def operations_summary(operations) when is_list(operations) do
    base = Map.new(@domains, fn d -> {d, 0} end)

    Enum.reduce(operations, base, fn op, acc ->
      Map.update(acc, op.domain, 1, &(&1 + 1))
    end)
  end

  @doc """
  Generates a human-readable description of semantic operations.

  Useful for providing context to AI assistants.

  ## Examples

      {:ok, ops} = Semantic.extract_operations(doc)
      description = Semantic.describe_operations(ops)
      # => "5 database operations (3 retrieve, 2 create), 2 HTTP requests (get)"
  """
  @spec describe_operations([operation()]) :: String.t()
  def describe_operations(operations) when is_list(operations) do
    by_domain = Enum.group_by(operations, & &1.domain)

    descriptions =
      @domains
      |> Enum.map(fn domain ->
        ops = Map.get(by_domain, domain, [])

        if ops == [] do
          nil
        else
          by_op = Enum.frequencies_by(ops, & &1.operation)
          op_details = Enum.map_join(by_op, ", ", fn {op, count} -> "#{count} #{op}" end)
          "#{length(ops)} #{domain_label(domain)} (#{op_details})"
        end
      end)
      |> Enum.reject(&is_nil/1)

    if descriptions == [] do
      "No semantic operations detected"
    else
      Enum.join(descriptions, ", ")
    end
  end

  # Private functions

  defp detect_language(path) do
    case Path.extname(path) do
      ".ex" -> :elixir
      ".exs" -> :elixir
      ".erl" -> :erlang
      ".hrl" -> :erlang
      ".py" -> :python
      ".rb" -> :ruby
      ".js" -> :javascript
      ".jsx" -> :javascript
      ".ts" -> :javascript
      ".tsx" -> :javascript
      _ -> :unknown
    end
  end

  defp extract_ops_from_ast(ast, language, acc) do
    case ast do
      {:function_call, meta, args} when is_list(meta) ->
        op = extract_op_from_meta(meta)
        new_acc = if op, do: [op | acc], else: acc
        # Recurse into args
        Enum.reduce(args, new_acc, &extract_ops_from_ast(&1, language, &2))

      {:attribute_access, meta, children} when is_list(meta) ->
        op = extract_op_from_meta(meta)
        new_acc = if op, do: [op | acc], else: acc
        # Recurse into children
        Enum.reduce(children, new_acc, &extract_ops_from_ast(&1, language, &2))

      {_type, _meta, children} when is_list(children) ->
        Enum.reduce(children, acc, &extract_ops_from_ast(&1, language, &2))

      list when is_list(list) ->
        Enum.reduce(list, acc, &extract_ops_from_ast(&1, language, &2))

      _ ->
        acc
    end
  end

  defp extract_op_from_meta(meta) do
    case Keyword.get(meta, :op_kind) do
      nil ->
        nil

      op_kind when is_list(op_kind) ->
        %{
          domain: OpKind.domain(op_kind),
          operation: OpKind.operation(op_kind),
          target: OpKind.target(op_kind),
          framework: Keyword.get(op_kind, :framework),
          async: Keyword.get(op_kind, :async, false),
          line: Keyword.get(meta, :line)
        }
    end
  end

  defp build_context(path, language, operations) do
    by_domain =
      Enum.group_by(operations, & &1.domain)
      |> Enum.map(fn {domain, ops} ->
        # Group by operation and count
        grouped =
          ops
          |> Enum.group_by(fn op -> {op.operation, op.target, op.framework} end)
          |> Enum.map(fn {{operation, target, framework}, group} ->
            %{
              operation: operation,
              target: target,
              framework: framework,
              count: length(group)
            }
          end)

        {domain, grouped}
      end)
      |> Map.new()

    # Fill in missing domains with empty lists
    domains_map = Map.new(@domains, fn d -> {d, Map.get(by_domain, d, [])} end)

    security_relevant =
      Enum.any?([:db, :auth, :file, :http, :external_api], fn d ->
        Map.get(domains_map, d, []) != []
      end)

    %{
      file: path,
      language: language,
      domains: domains_map,
      summary: describe_operations(operations),
      security_relevant: security_relevant,
      operation_count: length(operations),
      timestamp: DateTime.utc_now()
    }
  end

  defp domain_label(:db), do: "database operations"
  defp domain_label(:http), do: "HTTP requests"
  defp domain_label(:auth), do: "auth operations"
  defp domain_label(:cache), do: "cache operations"
  defp domain_label(:queue), do: "queue operations"
  defp domain_label(:file), do: "file operations"
  defp domain_label(:external_api), do: "external API calls"

  defp find_source_files(path, recursive) do
    pattern =
      if recursive do
        Path.join([path, "**", "*.{ex,exs,erl,hrl,py,rb,js,jsx,ts,tsx}"])
      else
        Path.join([path, "*.{ex,exs,erl,hrl,py,rb,js,jsx,ts,tsx}"])
      end

    files = Path.wildcard(pattern)
    {:ok, files}
  rescue
    e -> {:error, {:wildcard_failed, e}}
  end

  defp analyze_files_parallel(files, opts, max_concurrency) do
    files
    |> Task.async_stream(
      fn file ->
        case analyze_file(file, opts) do
          {:ok, context} -> context
          {:error, _} -> nil
        end
      end,
      max_concurrency: max_concurrency,
      timeout: 30_000
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, _reason} -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end
end
