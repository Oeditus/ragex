defmodule Ragex.MCP.Handlers.ImageToolsTest do
  use ExUnit.Case, async: true

  alias Ragex.MCP.Handlers.ImageTools
  alias Ragex.MCP.Handlers.Tools

  setup do
    tmp_dir = System.tmp_dir!() |> Path.join("mcp_image_tools_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)

    base_path = Path.join(tmp_dir, "test_base.png")
    {:ok, img} = Image.new(100, 100, color: [200, 100, 50])
    {:ok, _} = Image.write(img, base_path)

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    %{tmp_dir: tmp_dir, base_path: base_path}
  end

  test "tool_definitions lists 10 image tools" do
    defs = ImageTools.tool_definitions()
    assert length(defs) == 10

    names = Enum.map(defs, & &1.name)
    assert "image_info" in names
    assert "image_resize" in names
    assert "image_crop" in names
    assert "image_rotate" in names
    assert "image_convert" in names
    assert "image_apply_filter" in names
    assert "image_composite" in names
    assert "image_compare" in names
    assert "image_avatar" in names
    assert "image_draw_text" in names
  end

  test "Tools.list_tools contains image tools" do
    %{tools: all_tools} = Tools.list_tools()
    all_names = Enum.map(all_tools, & &1.name)
    assert "image_info" in all_names
    assert "image_convert" in all_names
  end

  test "dispatch image_info tool via Tools.call_tool", %{base_path: base_path} do
    {:ok, result} = Tools.call_tool("image_info", %{"path" => base_path})
    assert result.width == 100
    assert result.height == 100
  end

  test "dispatch image_resize tool", %{tmp_dir: tmp_dir, base_path: base_path} do
    out_path = Path.join(tmp_dir, "resized.png")

    {:ok, result} =
      Tools.call_tool("image_resize", %{
        "path" => base_path,
        "output_path" => out_path,
        "scale" => 0.5
      })

    assert result.width == 50
    assert result.height == 50
  end

  test "dispatch image_convert tool", %{tmp_dir: tmp_dir, base_path: base_path} do
    out_path = Path.join(tmp_dir, "out.jpg")

    {:ok, result} =
      Tools.call_tool("image_convert", %{
        "path" => base_path,
        "output_path" => out_path,
        "quality" => 80
      })

    assert result.format == "jpg"
    assert File.exists?(out_path)
  end

  test "dispatch image_avatar tool", %{tmp_dir: tmp_dir, base_path: base_path} do
    out_path = Path.join(tmp_dir, "av.png")

    {:ok, result} =
      Tools.call_tool("image_avatar", %{
        "path" => base_path,
        "output_path" => out_path,
        "size" => 64,
        "shape" => "circle"
      })

    assert result.size == 64
  end
end
