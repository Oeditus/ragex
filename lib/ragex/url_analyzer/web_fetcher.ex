defmodule Ragex.URLAnalyzer.WebFetcher do
  @moduledoc """
  Fetches and parses web pages, documentation, raw code files, and API specifications.
  """

  require Logger

  @doc """
  Fetches a web page or file, parses its content, extracts metadata, headings,
  code snippets, and converts HTML to clean markdown/text.
  """
  def fetch_and_parse(url_string, opts \\ []) do
    user_agent = Keyword.get(opts, :user_agent, "Ragex-URL-Analyzer/1.0")
    headers = [{"user-agent", user_agent}, {"accept", "*/*"}]

    case Req.get(url_string, headers: headers, redirect: true, max_redirects: 5) do
      {:ok, %Req.Response{status: status, body: body, headers: resp_headers}}
      when status in 200..299 ->
        content_type = get_header(resp_headers, "content-type") || "text/html"

        parsed = parse_content(body, content_type, url_string)

        report = %{
          http_status: status,
          content_type: content_type,
          metadata: parsed.metadata,
          headings: parsed.headings,
          code_blocks: parsed.code_blocks,
          links: parsed.links,
          extracted_text: parsed.extracted_text,
          summary: parsed.summary
        }

        {:ok, report}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status_error, status}}

      {:error, reason} ->
        Logger.error("HTTP fetch failed for #{url_string}: #{inspect(reason)}")
        {:error, {:http_request_failed, reason}}
    end
  end

  defp parse_content(body, content_type, url_string) do
    cond do
      String.contains?(content_type, "json") or is_map(body) ->
        parse_json_content(body, url_string)

      String.contains?(content_type, "text/plain") or raw_code_url?(url_string) ->
        parse_raw_text(to_string(body))

      true ->
        parse_html_content(to_string(body))
    end
  end

  defp parse_json_content(body, _url) when is_map(body) do
    title = Map.get(body, "title") || Map.get(body, "name") || "JSON API Data"
    keys = Map.keys(body)

    endpoints =
      case Map.get(body, "paths") do
        paths when is_map(paths) -> Map.keys(paths)
        _ -> []
      end

    %{
      metadata: %{title: title, json_keys_count: length(keys)},
      headings: endpoints,
      code_blocks: [],
      links: [],
      extracted_text: Jason.encode!(body, pretty: true) |> String.slice(0, 5000),
      summary: %{
        overview: "API Specification or JSON document containing #{length(keys)} top-level keys.",
        endpoints_count: length(endpoints)
      }
    }
  end

  defp parse_json_content(body, url) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_json_content(decoded, url)
      _ -> parse_raw_text(body)
    end
  end

  defp parse_raw_text(text) do
    lines = String.split(text, "\n")

    %{
      metadata: %{title: "Raw Code / Text File", lines_count: length(lines)},
      headings: [],
      code_blocks: [String.slice(text, 0, 4000)],
      links: [],
      extracted_text: String.slice(text, 0, 5000),
      summary: %{
        overview: "Raw text/code file with #{length(lines)} lines.",
        character_count: String.length(text)
      }
    }
  end

  defp parse_html_content(html) do
    title = extract_regex(html, ~r/<title[^>]*>(.*?)<\/title>/is) || "Untitled Web Page"

    meta_desc =
      extract_regex(html, ~r/<meta\s+name=["']description["']\s+content=["'](.*?)["']/is)

    headings = extract_all_regex(html, ~r/<h[1-3][^>]*>(.*?)<\/h[1-3]>/is)
    code_blocks = extract_all_regex(html, ~r/<pre[^>]*>(.*?)<\/pre>/is)
    links = extract_all_regex(html, ~r/<a\s+[^>]*href=["'](https?:\/\/[^"']+)["']/is)

    clean_text = strip_html(html)

    %{
      metadata: %{
        title: clean_str(title),
        description: clean_str(meta_desc || "")
      },
      headings: Enum.map(headings, &clean_str/1),
      code_blocks:
        Enum.map(code_blocks, fn b -> strip_html(b) |> clean_str() end) |> Enum.slice(0, 10),
      links: Enum.uniq(links) |> Enum.slice(0, 20),
      extracted_text: String.slice(clean_text, 0, 5000),
      summary: %{
        overview: clean_str(meta_desc || String.slice(clean_text, 0, 300)),
        headings_count: length(headings),
        code_blocks_count: length(code_blocks)
      }
    }
  end

  defp raw_code_url?(url) do
    ext = Path.extname(url) |> String.downcase()

    ext in [
      ".ex",
      ".exs",
      ".py",
      ".js",
      ".ts",
      ".rs",
      ".go",
      ".c",
      ".cpp",
      ".java",
      ".json",
      ".yaml",
      ".yml",
      ".md"
    ]
  end

  defp extract_regex(text, regex) do
    case Regex.run(regex, text) do
      [_, match] -> match
      _ -> nil
    end
  end

  defp extract_all_regex(text, regex) do
    Regex.scan(regex, text)
    |> Enum.map(fn
      [_, match] -> match
      [match] -> match
    end)
  end

  defp strip_html(html) do
    html
    |> String.replace(~r/<script[^>]*>.*?<\/script>/is, " ")
    |> String.replace(~r/<style[^>]*>.*?<\/style>/is, " ")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp clean_str(str) do
    str
    |> strip_html()
    |> String.trim()
  end

  defp get_header(headers, name) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == name, do: to_string(v)
    end)
  end
end
