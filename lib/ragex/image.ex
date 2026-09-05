defmodule Ragex.Image do
  @moduledoc """
  Core image manipulation functions backed by the `Image` library (Vix/libvips).
  """

  @doc """
  Returns `true` when the optional `:image` dependency is compiled and loadable.

  `:image` is a native/NIF-backed dependency (Vix/libvips) that cannot be
  loaded from inside an escript archive, so callers embedding Ragex as a
  library should check this before relying on image-processing features.
  """
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(Image)
  end

  @doc """
  Get detailed information and metadata for an image file.
  """
  def info(path) when is_binary(path) do
    with {:ok, image} <- Image.open(path) do
      {width, height, bands} = Image.shape(image)
      colorspace = Image.colorspace(image)
      has_alpha = Image.has_alpha?(image)

      exif =
        try do
          Image.exif(image)
        rescue
          _ -> nil
        end

      aspect =
        try do
          Image.aspect(image)
        rescue
          _ -> nil
        end

      dominant_color =
        case Image.dominant_color(image) do
          {:ok, color} when is_list(color) -> color
          _ -> nil
        end

      file_size =
        case File.stat(path) do
          {:ok, stat} -> stat.size
          _ -> nil
        end

      format = Path.extname(path) |> String.trim_leading(".") |> String.downcase()

      {:ok,
       %{
         path: path,
         width: width,
         height: height,
         bands: bands,
         colorspace: colorspace,
         has_alpha: has_alpha,
         format: format,
         aspect: aspect,
         dominant_color: dominant_color,
         exif: exif,
         file_size_bytes: file_size
       }}
    end
  end

  @doc """
  Resize an image by scale factor, width/height dimensions, or crop focus.
  """
  def resize(path, opts) when is_binary(path) and is_list(opts) do
    output_path = Keyword.get(opts, :output_path, path)
    scale = Keyword.get(opts, :scale)
    width = Keyword.get(opts, :width)
    height = Keyword.get(opts, :height)
    crop_focus = Keyword.get(opts, :crop, :none)
    quality = Keyword.get(opts, :quality, 80)

    with {:ok, image} <- Image.open(path) do
      resized_result =
        cond do
          scale && is_number(scale) ->
            Image.resize(image, scale * 1.0)

          width && height ->
            dim_str = "#{width}x#{height}"

            if crop_focus != :none and crop_focus != "none" do
              crop_atom =
                if is_binary(crop_focus), do: String.to_atom(crop_focus), else: crop_focus

              Image.thumbnail(image, dim_str, crop: crop_atom)
            else
              Image.thumbnail(image, dim_str)
            end

          width ->
            Image.thumbnail(image, width)

          height ->
            {_w, h, _} = Image.shape(image)
            scale_val = height / h
            Image.resize(image, scale_val)

          true ->
            {:ok, image}
        end

      with {:ok, resized} <- resized_result,
           {:ok, saved} <- Image.write(resized, output_path, quality: quality) do
        {new_w, new_h, new_b} = Image.shape(saved)

        {:ok,
         %{
           input_path: path,
           output_path: output_path,
           width: new_w,
           height: new_h,
           bands: new_b
         }}
      end
    end
  end

  @doc """
  Crop an image by bounding box or auto-trim.
  """
  def crop(path, opts) when is_binary(path) and is_list(opts) do
    output_path = Keyword.get(opts, :output_path, path)
    auto_trim = Keyword.get(opts, :auto_trim, false)
    left = Keyword.get(opts, :left, 0)
    top = Keyword.get(opts, :top, 0)
    width = Keyword.get(opts, :width)
    height = Keyword.get(opts, :height)
    quality = Keyword.get(opts, :quality, 80)

    with {:ok, image} <- Image.open(path) do
      cropped_result =
        if auto_trim do
          case Image.trim(image) do
            {:ok, trimmed} -> {:ok, trimmed}
            # Matched as a plain map (not `%Image.Error{}`) so this module
            # still compiles when the optional `:image` dependency -- and
            # thus `Image.Error` -- is absent from the build.
            {:error, %{message: "Could not find anything to trim"}} -> {:ok, image}
            error -> error
          end
        else
          {img_w, img_h, _} = Image.shape(image)
          crop_w = width || img_w - left
          crop_h = height || img_h - top
          Image.crop(image, left, top, crop_w, crop_h)
        end

      with {:ok, cropped} <- cropped_result,
           {:ok, saved} <- Image.write(cropped, output_path, quality: quality) do
        {new_w, new_h, _} = Image.shape(saved)

        {:ok,
         %{
           input_path: path,
           output_path: output_path,
           left: left,
           top: top,
           width: new_w,
           height: new_h
         }}
      end
    end
  end

  @doc """
  Rotate or flip an image.
  """
  def rotate(path, opts) when is_binary(path) and is_list(opts) do
    output_path = Keyword.get(opts, :output_path, path)
    angle = Keyword.get(opts, :angle)
    flip = Keyword.get(opts, :flip)
    autorotate = Keyword.get(opts, :autorotate, false)
    quality = Keyword.get(opts, :quality, 80)

    with {:ok, image} <- Image.open(path) do
      step1 =
        if autorotate do
          case Image.autorotate(image) do
            {:ok, {rot, _flags}} -> {:ok, rot}
            error -> error
          end
        else
          {:ok, image}
        end

      with {:ok, img1} <- step1 do
        step2 =
          if angle && is_number(angle) && angle != 0 do
            Image.rotate(img1, angle)
          else
            {:ok, img1}
          end

        with {:ok, img2} <- step2 do
          flip_atom = if is_binary(flip), do: String.to_atom(flip), else: flip

          step3 =
            case flip_atom do
              :horizontal ->
                Image.flip(img2, :horizontal)

              :vertical ->
                Image.flip(img2, :vertical)

              :both ->
                with {:ok, h} <- Image.flip(img2, :horizontal) do
                  Image.flip(h, :vertical)
                end

              _ ->
                {:ok, img2}
            end

          with {:ok, final_img} <- step3,
               {:ok, saved} <- Image.write(final_img, output_path, quality: quality) do
            {new_w, new_h, _} = Image.shape(saved)

            {:ok,
             %{
               input_path: path,
               output_path: output_path,
               width: new_w,
               height: new_h
             }}
          end
        end
      end
    end
  end

  @doc """
  Convert image format (e.g. PNG, JPEG, WebP, AVIF, TIFF, GIF).
  """
  def convert(path, output_path, opts \\ []) when is_binary(path) and is_binary(output_path) do
    quality = Keyword.get(opts, :quality, 80)
    strip_metadata = Keyword.get(opts, :strip_metadata, false)

    with {:ok, image} <- Image.open(path) do
      processed_image =
        if strip_metadata do
          case Image.minimize_metadata(image) do
            {:ok, min_img} -> min_img
            _ -> image
          end
        else
          image
        end

      with {:ok, saved} <- Image.write(processed_image, output_path, quality: quality) do
        {width, height, bands} = Image.shape(saved)

        file_size =
          case File.stat(output_path) do
            {:ok, stat} -> stat.size
            _ -> nil
          end

        {:ok,
         %{
           input_path: path,
           output_path: output_path,
           format: Path.extname(output_path) |> String.trim_leading(".") |> String.downcase(),
           width: width,
           height: height,
           bands: bands,
           file_size_bytes: file_size
         }}
      end
    end
  end

  @doc """
  Apply visual filters / enhancements.
  """
  def apply_filter(path, filter_name, opts \\ []) when is_binary(path) do
    output_path = Keyword.get(opts, :output_path, path)
    quality = Keyword.get(opts, :quality, 80)
    sigma = Keyword.get(opts, :sigma, 2.0)
    factor = Keyword.get(opts, :factor, 1.2)

    filter_str = to_string(filter_name)

    with {:ok, image} <- Image.open(path) do
      filtered_result =
        case filter_str do
          "grayscale" -> Image.to_colorspace(image, :bw)
          "blur" -> Image.blur(image, sigma: sigma)
          "sharpen" -> Image.sharpen(image)
          "brightness" -> Image.brightness(image, factor)
          "contrast" -> Image.contrast(image, factor)
          "invert" -> Image.invert(image)
          "reduce_noise" -> Image.reduce_noise(image)
          "pixelate" -> Image.pixelate(image, trunc(factor))
          "sepia" -> Image.sepia(image)
          other -> {:error, "Unsupported filter: #{other}"}
        end

      with {:ok, filtered} <- filtered_result,
           {:ok, saved} <- Image.write(filtered, output_path, quality: quality) do
        {width, height, _} = Image.shape(saved)

        {:ok,
         %{
           input_path: path,
           output_path: output_path,
           filter: filter_str,
           width: width,
           height: height
         }}
      end
    end
  end

  @doc """
  Composite (overlay) an image on top of a base image.
  """
  def composite(base_path, overlay_path, output_path, opts \\ [])
      when is_binary(base_path) and is_binary(overlay_path) and is_binary(output_path) do
    x = Keyword.get(opts, :x, 0)
    y = Keyword.get(opts, :y, 0)
    opacity = Keyword.get(opts, :opacity, 1.0)
    quality = Keyword.get(opts, :quality, 80)

    with {:ok, base_img} <- Image.open(base_path),
         {:ok, overlay_img} <- Image.open(overlay_path) do
      overlay_processed =
        if opacity < 1.0 do
          case Image.opacity(overlay_img, opacity) do
            {:ok, op_img} -> op_img
            _ -> overlay_img
          end
        else
          overlay_img
        end

      with {:ok, composed} <- Image.compose(base_img, overlay_processed, x: x, y: y),
           {:ok, saved} <- Image.write(composed, output_path, quality: quality) do
        {width, height, _} = Image.shape(saved)

        {:ok,
         %{
           base_path: base_path,
           overlay_path: overlay_path,
           output_path: output_path,
           width: width,
           height: height,
           x: x,
           y: y
         }}
      end
    end
  end

  @doc """
  Compare two images for visual diff/similarity.
  """
  def compare(image_a_path, image_b_path, opts \\ [])
      when is_binary(image_a_path) and is_binary(image_b_path) do
    diff_output_path = Keyword.get(opts, :diff_output_path)

    with {:ok, img_a} <- Image.open(image_a_path),
         {:ok, img_b} <- Image.open(image_b_path),
         {:ok, diff_score, diff_img} <- Image.compare(img_a, img_b) do
      diff_saved_path =
        if diff_output_path do
          case Image.write(diff_img, diff_output_path) do
            {:ok, _} -> diff_output_path
            _ -> nil
          end
        else
          nil
        end

      {:ok,
       %{
         image_a: image_a_path,
         image_b: image_b_path,
         difference_score: diff_score,
         identical: diff_score == 0.0,
         diff_image_path: diff_saved_path
       }}
    end
  end

  @doc """
  Generate a circular, squircle, or square avatar image.
  """
  def avatar(path, output_path, opts \\ []) when is_binary(path) and is_binary(output_path) do
    size = Keyword.get(opts, :size, 180)
    shape_val = Keyword.get(opts, :shape, :circle)
    quality = Keyword.get(opts, :quality, 80)

    shape_atom =
      case to_string(shape_val) do
        "squircle" -> :squircle
        "square" -> :square
        _ -> :circle
      end

    with {:ok, image} <- Image.open(path),
         {:ok, av} <- Image.avatar(image, size: size, shape: shape_atom),
         {:ok, saved} <- Image.write(av, output_path, quality: quality) do
      {width, height, bands} = Image.shape(saved)

      {:ok,
       %{
         input_path: path,
         output_path: output_path,
         size: size,
         shape: shape_atom,
         width: width,
         height: height,
         bands: bands
       }}
    end
  end

  @doc """
  Render text onto an image.
  """
  def draw_text(path, output_path, text, opts \\ [])
      when is_binary(path) and is_binary(output_path) and is_binary(text) do
    x = Keyword.get(opts, :x, 10)
    y = Keyword.get(opts, :y, 10)
    font_size = Keyword.get(opts, :font_size, 24)
    text_color = Keyword.get(opts, :text_color, "white")
    bg_color = Keyword.get(opts, :background_color)
    quality = Keyword.get(opts, :quality, 80)

    color_opt =
      case text_color do
        "white" -> :white
        "black" -> :black
        "red" -> :red
        "green" -> :green
        "blue" -> :blue
        "yellow" -> :yellow
        other when is_binary(other) -> String.to_atom(other)
        other -> other
      end

    with {:ok, image} <- Image.open(path) do
      text_opts = [font_size: font_size, text_fill_color: color_opt]

      text_opts =
        if bg_color do
          bg_atom =
            case bg_color do
              "black" -> :black
              "white" -> :white
              other when is_binary(other) -> String.to_atom(other)
              other -> other
            end

          text_opts ++ [background_fill_color: bg_atom]
        else
          text_opts
        end

      with {:ok, text_img} <- Image.Text.text(text, text_opts),
           {:ok, composed} <- Image.compose(image, text_img, x: x, y: y),
           {:ok, saved} <- Image.write(composed, output_path, quality: quality) do
        {width, height, _} = Image.shape(saved)

        {:ok,
         %{
           input_path: path,
           output_path: output_path,
           text: text,
           x: x,
           y: y,
           width: width,
           height: height
         }}
      end
    end
  end
end
