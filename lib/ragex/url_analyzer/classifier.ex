defmodule Ragex.URLAnalyzer.Classifier do
  @moduledoc """
  Classifies input URLs into specific target categories for tailored analysis:

  - `:git_repo` - GitHub, GitLab, Bitbucket, or standard Git repository URLs.
  - `:raw_code` - Direct links to code files, gists, or raw source URLs.
  - `:api_spec` - OpenAPI/Swagger or JSON/YAML API specification endpoints.
  - `:web_page` - Web pages, technical documentation, or HTML sites.
  """

  @git_hosts ["github.com", "gitlab.com", "bitbucket.org", "codeberg.org", "dev.azure.com"]
  @code_extensions [
    ".ex",
    ".exs",
    ".erl",
    ".hrl",
    ".py",
    ".js",
    ".jsx",
    ".ts",
    ".tsx",
    ".rs",
    ".go",
    ".rb",
    ".c",
    ".h",
    ".cpp",
    ".hpp",
    ".java",
    ".kt",
    ".swift",
    ".cs",
    ".php",
    ".sh",
    ".bash",
    ".zsh",
    ".sql",
    ".hs"
  ]
  @api_spec_extensions [".json", ".yaml", ".yml"]

  @doc """
  Determines the target type for a given URL string.

  Returns `{:ok, target_type, metadata}` or `{:error, reason}`.
  """
  @spec classify(String.t() | term()) :: {:ok, atom(), map()} | {:error, :invalid_url}
  def classify(url_string) when is_binary(url_string) do
    url_string = String.trim(url_string)

    case URI.parse(url_string) do
      %URI{scheme: scheme, host: host, path: path} when not is_nil(scheme) and not is_nil(host) ->
        path = path || ""
        metadata = %{url: url_string, scheme: scheme, host: host, path: path}
        target_type = classify_url(scheme, host, path, url_string)
        {:ok, target_type, metadata}

      _ ->
        {:error, :invalid_url}
    end
  end

  def classify(_), do: {:error, :invalid_url}

  defp classify_url(_scheme, host, path, url_string) do
    cond do
      # Raw GitHub/GitLab files or Gists
      raw_file_url?(host, path) ->
        :raw_code

      # Git repository URL
      git_repo_url?(host, path, url_string) ->
        :git_repo

      # Direct code file extensions
      has_extension?(path, @code_extensions) ->
        :raw_code

      # API specification files (OpenAPI/Swagger/JSON Schema)
      api_spec_url?(path) ->
        :api_spec

      # Default fallback to web page
      true ->
        :web_page
    end
  end

  defp git_repo_url?(host, path, url_string) do
    ends_with_git? = String.ends_with?(url_string, ".git") or String.ends_with?(path, ".git")
    known_host? = Enum.any?(@git_hosts, &String.contains?(host, &1))

    cond do
      ends_with_git? ->
        true

      known_host? ->
        path_segments = path |> String.split("/", trim: true)

        case path_segments do
          # e.g., github.com/owner/repo or github.com/owner/repo/
          [_owner, _repo] ->
            true

          # e.g., github.com/owner/repo/tree/main
          [_owner, _repo, "tree" | _] ->
            true

          _ ->
            false
        end

      true ->
        false
    end
  end

  defp raw_file_url?(host, path) do
    cond do
      String.contains?(host, "raw.githubusercontent.com") ->
        true

      String.contains?(host, "gist.github.com") and String.contains?(path, "/raw") ->
        true

      String.contains?(host, "gitlab.com") and String.contains?(path, "/-/raw/") ->
        true

      String.contains?(path, "/raw/") or String.contains?(path, "/-/raw/") ->
        true

      true ->
        false
    end
  end

  defp api_spec_url?(path) do
    has_extension?(path, @api_spec_extensions) and
      (String.contains?(path, "openapi") or String.contains?(path, "swagger") or
         String.contains?(path, "schema"))
  end

  defp has_extension?(path, extensions) do
    ext = Path.extname(path) |> String.downcase()
    ext in extensions
  end
end
