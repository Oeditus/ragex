defmodule Ragex.ImageTest do
  use ExUnit.Case, async: true

  alias Ragex.Image, as: RagexImage

  setup do
    tmp_dir = System.tmp_dir!() |> Path.join("ragex_image_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)

    base_path = Path.join(tmp_dir, "test_base.png")
    {:ok, img} = Image.new(200, 150, color: [100, 150, 200])
    {:ok, _} = Image.write(img, base_path)

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    %{tmp_dir: tmp_dir, base_path: base_path}
  end

  describe "available?/0" do
    test "returns true when the optional :image dependency is compiled and loadable" do
      # In the standard dev/test environment :image is present. See
      # scripts/verify_optional_ml_deps.sh for a test that exercises the
      # genuinely-absent case (compile + boot with the dependency removed).
      assert RagexImage.available?() == true
    end
  end

  describe "Nx compatibility" do
    test "converts an image to a tensor and back without changing pixels", %{base_path: path} do
      assert {:ok, image} = Image.open(path)
      assert {:ok, tensor} = Image.to_nx(image, backend: Nx.BinaryBackend)
      assert Nx.shape(tensor) == {150, 200, 3}
      assert Nx.type(tensor) == {:u, 8}
      assert Nx.names(tensor) == [:height, :width, :bands]

      assert {:ok, restored} = Image.from_nx(tensor)
      assert Image.shape(restored) == Image.shape(image)
      assert {:ok, restored_tensor} = Image.to_nx(restored, backend: Nx.BinaryBackend)
      assert Nx.to_binary(restored_tensor) == Nx.to_binary(tensor)
    end

    test "preserves nonuniform pixels in height-first and width-first tensors" do
      original = Nx.iota({3, 4, 3}, type: :u8, backend: Nx.BinaryBackend)
      assert {:ok, image} = Image.from_nx(original)

      for {layout, shape, names} <- [
            {:hwc, {3, 4, 3}, [:height, :width, :bands]},
            {:whc, {4, 3, 3}, [:width, :height, :bands]}
          ] do
        assert {:ok, tensor} = Image.to_nx(image, shape: layout, backend: Nx.BinaryBackend)
        assert Nx.shape(tensor) == shape
        assert Nx.names(tensor) == names
        assert {:ok, restored} = Image.from_nx(tensor)
        assert {:ok, restored_tensor} = Image.to_nx(restored, backend: Nx.BinaryBackend)
        assert Nx.to_binary(restored_tensor) == Nx.to_binary(original)
      end
    end

    test "processes image tensors through NxImage before converting back", %{base_path: path} do
      assert {:ok, image} = Image.open(path)
      assert {:ok, tensor} = Image.to_nx(image, backend: Nx.BinaryBackend)
      resized = NxImage.resize(tensor, {30, 40}, method: :nearest)

      assert {:ok, restored} = Image.from_nx(resized)
      assert Image.shape(restored) == {40, 30, 3}
      assert {:ok, restored_tensor} = Image.to_nx(restored, backend: Nx.BinaryBackend)
      assert Nx.to_binary(restored_tensor) == Nx.to_binary(resized)
    end
  end

  test "info/1 returns image metadata", %{base_path: base_path} do
    assert {:ok, info} = RagexImage.info(base_path)
    assert info.width == 200
    assert info.height == 150
    assert info.format == "png"
    assert info.colorspace == :srgb
    assert is_integer(info.file_size_bytes)
  end

  test "resize/2 with scale factor", %{tmp_dir: tmp_dir, base_path: base_path} do
    output_path = Path.join(tmp_dir, "resized.png")
    assert {:ok, res} = RagexImage.resize(base_path, output_path: output_path, scale: 0.5)
    assert res.width == 100
    assert res.height == 75
    assert File.exists?(output_path)
  end

  test "resize/2 with target dimensions and crop focus", %{tmp_dir: tmp_dir, base_path: base_path} do
    output_path1 = Path.join(tmp_dir, "thumb_contain.png")

    assert {:ok, res1} =
             RagexImage.resize(base_path, output_path: output_path1, width: 100, height: 100)

    assert res1.width == 100
    assert res1.height == 75

    output_path2 = Path.join(tmp_dir, "thumb_crop.png")

    assert {:ok, res2} =
             RagexImage.resize(base_path,
               output_path: output_path2,
               width: 100,
               height: 100,
               crop: :center
             )

    assert res2.width == 100
    assert res2.height == 100
  end

  test "crop/2 with explicit box", %{tmp_dir: tmp_dir, base_path: base_path} do
    output_path = Path.join(tmp_dir, "cropped.png")

    assert {:ok, res} =
             RagexImage.crop(base_path,
               output_path: output_path,
               left: 10,
               top: 10,
               width: 50,
               height: 40
             )

    assert res.width == 50
    assert res.height == 40
  end

  test "rotate/2 and flip", %{tmp_dir: tmp_dir, base_path: base_path} do
    output_path = Path.join(tmp_dir, "rotated.png")

    assert {:ok, res} =
             RagexImage.rotate(base_path, output_path: output_path, angle: 90, flip: :horizontal)

    assert res.width == 150
    assert res.height == 200
  end

  test "convert/3 between formats", %{tmp_dir: tmp_dir, base_path: base_path} do
    output_path = Path.join(tmp_dir, "converted.jpg")

    assert {:ok, res} =
             RagexImage.convert(base_path, output_path, quality: 75, strip_metadata: true)

    assert res.format == "jpg"
    assert File.exists?(output_path)
  end

  test "apply_filter/3 with grayscale and blur", %{tmp_dir: tmp_dir, base_path: base_path} do
    gray_path = Path.join(tmp_dir, "gray.png")
    assert {:ok, res} = RagexImage.apply_filter(base_path, "grayscale", output_path: gray_path)
    assert res.filter == "grayscale"

    blur_path = Path.join(tmp_dir, "blur.png")

    assert {:ok, res2} =
             RagexImage.apply_filter(base_path, "blur", output_path: blur_path, sigma: 3.0)

    assert res2.filter == "blur"
  end

  test "composite/4 overlaying two images", %{tmp_dir: tmp_dir, base_path: base_path} do
    overlay_path = Path.join(tmp_dir, "overlay.png")
    {:ok, overlay_img} = Image.new(40, 40, color: [255, 0, 0])
    {:ok, _} = Image.write(overlay_img, overlay_path)

    out_path = Path.join(tmp_dir, "composite.png")
    assert {:ok, res} = RagexImage.composite(base_path, overlay_path, out_path, x: 10, y: 20)
    assert res.x == 10
    assert res.y == 20
    assert File.exists?(out_path)
  end

  test "compare/3 visual difference", %{tmp_dir: tmp_dir, base_path: base_path} do
    diff_img_path = Path.join(tmp_dir, "diff.png")
    assert {:ok, res} = RagexImage.compare(base_path, base_path, diff_output_path: diff_img_path)
    assert res.identical == true
    assert res.difference_score == 0.0
  end

  test "avatar/3 generation", %{tmp_dir: tmp_dir, base_path: base_path} do
    out_path = Path.join(tmp_dir, "avatar.png")
    assert {:ok, res} = RagexImage.avatar(base_path, out_path, size: 80, shape: :circle)
    assert res.size == 80
    assert res.shape == :circle
  end

  test "draw_text/4 text rendering", %{tmp_dir: tmp_dir, base_path: base_path} do
    out_path = Path.join(tmp_dir, "text_out.png")

    assert {:ok, res} =
             RagexImage.draw_text(base_path, out_path, "Hello Test",
               font_size: 20,
               text_color: "red",
               x: 5,
               y: 5
             )

    assert res.text == "Hello Test"
    assert File.exists?(out_path)
  end
end
