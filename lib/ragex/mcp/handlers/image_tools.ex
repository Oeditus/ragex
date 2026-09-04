defmodule Ragex.MCP.Handlers.ImageTools do
  @moduledoc """
  MCP tool definitions and handlers for image operations backed by the `Image` library.

  Provides 10 tools:
  - `image_info` -- Extract metadata, dimensions, color space, EXIF, and format details
  - `image_resize` -- Resize image by scale factor, width, height, or thumbnail bounding box
  - `image_crop` -- Crop an image by bounding box or auto-trim whitespace/borders
  - `image_rotate` -- Rotate by angle or flip image horizontally/vertically
  - `image_convert` -- Convert image format (PNG, JPEG, WebP, AVIF, TIFF, GIF)
  - `image_apply_filter` -- Apply visual filter (grayscale, blur, sharpen, brightness, contrast, invert, sepia, etc.)
  - `image_composite` -- Overlay an image onto another at coordinates (x, y) with opacity
  - `image_compare` -- Compare two images for difference/similarity and generate visual diff
  - `image_avatar` -- Create a circular, squircle, or square avatar image
  - `image_draw_text` -- Render text overlay onto an image at specified position
  """

  alias Ragex.Image, as: RagexImage

  @doc "Returns the list of image tool definitions for tools/list."
  def tool_definitions do
    [
      %{
        name: "image_info",
        description:
          "Get detailed information and metadata for an image file (width, height, bands/channels, colorspace, format, aspect ratio, dominant color, EXIF metadata, file size).",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Absolute or relative path to the image file"
            }
          },
          required: ["path"]
        }
      },
      %{
        name: "image_resize",
        description:
          "Resize or scale an image by float scale factor, target width/height, or thumbnail mode. Saves output to path or overwrites input.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Path to input image file"},
            output_path: %{
              type: "string",
              description: "Output file path (defaults to overwriting input image)"
            },
            scale: %{type: "number", description: "Scale factor (e.g. 0.5 for 50%)"},
            width: %{type: "integer", description: "Target width in pixels"},
            height: %{type: "integer", description: "Target height in pixels"},
            crop: %{
              type: "string",
              description: "Crop focus strategy when resizing",
              enum: ["none", "center", "top_left", "bottom_right", "entropy", "attention"],
              default: "none"
            },
            quality: %{
              type: "integer",
              description: "Output quality (1 to 100)",
              default: 80
            }
          },
          required: ["path"]
        }
      },
      %{
        name: "image_crop",
        description:
          "Crop an image using explicit box coordinates (left, top, width, height) or auto-trim uniform borders.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Path to input image file"},
            output_path: %{type: "string", description: "Output file path"},
            left: %{type: "integer", description: "Left coordinate (px)", default: 0},
            top: %{type: "integer", description: "Top coordinate (px)", default: 0},
            width: %{type: "integer", description: "Crop width (px)"},
            height: %{type: "integer", description: "Crop height (px)"},
            auto_trim: %{
              type: "boolean",
              description: "Auto-trim uniform background/borders",
              default: false
            },
            quality: %{type: "integer", description: "Output quality (1 to 100)", default: 80}
          },
          required: ["path"]
        }
      },
      %{
        name: "image_rotate",
        description:
          "Rotate an image by degrees, flip horizontally/vertically, or auto-rotate using EXIF data.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Path to input image file"},
            output_path: %{type: "string", description: "Output file path"},
            angle: %{
              type: "number",
              description: "Rotation angle in degrees (e.g. 90, 180, 270, -90)"
            },
            flip: %{
              type: "string",
              description: "Flip direction",
              enum: ["none", "horizontal", "vertical", "both"],
              default: "none"
            },
            autorotate: %{
              type: "boolean",
              description: "Auto-rotate using EXIF orientation tag",
              default: false
            },
            quality: %{type: "integer", description: "Output quality (1 to 100)", default: 80}
          },
          required: ["path"]
        }
      },
      %{
        name: "image_convert",
        description:
          "Convert an image between formats (PNG, JPEG, WebP, AVIF, TIFF, GIF) with quality and metadata stripping options.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Path to input image file"},
            output_path: %{type: "string", description: "Path for converted output image"},
            quality: %{type: "integer", description: "Output quality (1 to 100)", default: 80},
            strip_metadata: %{
              type: "boolean",
              description: "Strip EXIF and metadata for smaller size",
              default: false
            }
          },
          required: ["path", "output_path"]
        }
      },
      %{
        name: "image_apply_filter",
        description:
          "Apply visual filters or image enhancements (grayscale, blur, sharpen, brightness, contrast, invert, sepia, pixelate, reduce_noise).",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Path to input image file"},
            output_path: %{type: "string", description: "Output file path"},
            filter: %{
              type: "string",
              description: "Filter operation to apply",
              enum: [
                "grayscale",
                "blur",
                "sharpen",
                "brightness",
                "contrast",
                "invert",
                "sepia",
                "pixelate",
                "reduce_noise"
              ]
            },
            sigma: %{
              type: "number",
              description: "Blur/sharpen strength factor (sigma)",
              default: 2.0
            },
            factor: %{
              type: "number",
              description: "Brightness/contrast factor or pixelate size",
              default: 1.2
            },
            quality: %{type: "integer", description: "Output quality (1 to 100)", default: 80}
          },
          required: ["path", "filter"]
        }
      },
      %{
        name: "image_composite",
        description:
          "Composite (overlay) an image on top of a base image at specific (x, y) coordinates with opacity control.",
        inputSchema: %{
          type: "object",
          properties: %{
            base_path: %{type: "string", description: "Path to background base image"},
            overlay_path: %{type: "string", description: "Path to foreground overlay image"},
            output_path: %{type: "string", description: "Path for composite output image"},
            x: %{type: "integer", description: "X offset in pixels", default: 0},
            y: %{type: "integer", description: "Y offset in pixels", default: 0},
            opacity: %{
              type: "number",
              description: "Overlay opacity (0.0 transparent to 1.0 opaque)",
              default: 1.0
            },
            quality: %{type: "integer", description: "Output quality (1 to 100)", default: 80}
          },
          required: ["base_path", "overlay_path", "output_path"]
        }
      },
      %{
        name: "image_compare",
        description:
          "Compare two images to measure visual differences, calculate difference score, and optionally export a visual diff image.",
        inputSchema: %{
          type: "object",
          properties: %{
            image_a_path: %{type: "string", description: "Path to first image"},
            image_b_path: %{type: "string", description: "Path to second image"},
            diff_output_path: %{
              type: "string",
              description: "Optional output path to save diff image highlighting changes"
            }
          },
          required: ["image_a_path", "image_b_path"]
        }
      },
      %{
        name: "image_avatar",
        description:
          "Generate a circular, squircle, or square avatar image with metadata removed.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Path to input image file"},
            output_path: %{type: "string", description: "Path for output avatar image"},
            size: %{type: "integer", description: "Avatar dimension in pixels", default: 180},
            shape: %{
              type: "string",
              description: "Avatar shape",
              enum: ["circle", "squircle", "square"],
              default: "circle"
            },
            quality: %{type: "integer", description: "Output quality (1 to 100)", default: 80}
          },
          required: ["path", "output_path"]
        }
      },
      %{
        name: "image_draw_text",
        description:
          "Render text overlay onto an image at specified position (x, y) with customizable size and color.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Path to input image file"},
            output_path: %{type: "string", description: "Path for output image file"},
            text: %{type: "string", description: "Text content to render"},
            x: %{type: "integer", description: "X coordinate (px)", default: 10},
            y: %{type: "integer", description: "Y coordinate (px)", default: 10},
            font_size: %{type: "integer", description: "Font size in pixels", default: 24},
            text_color: %{
              type: "string",
              description: "Text color name or hex (e.g. white, black, red)",
              default: "white"
            },
            background_color: %{
              type: "string",
              description: "Optional background box color (e.g. black, white)"
            },
            quality: %{type: "integer", description: "Output quality (1 to 100)", default: 80}
          },
          required: ["path", "output_path", "text"]
        }
      }
    ]
  end

  @doc "Dispatch an image tool call. Returns `{:ok, result}` or `{:error, reason}`."
  def call_tool(name, arguments) do
    case name do
      "image_info" -> handle_info(arguments)
      "image_resize" -> handle_resize(arguments)
      "image_crop" -> handle_crop(arguments)
      "image_rotate" -> handle_rotate(arguments)
      "image_convert" -> handle_convert(arguments)
      "image_apply_filter" -> handle_apply_filter(arguments)
      "image_composite" -> handle_composite(arguments)
      "image_compare" -> handle_compare(arguments)
      "image_avatar" -> handle_avatar(arguments)
      "image_draw_text" -> handle_draw_text(arguments)
      _ -> {:error, "Unknown image tool: #{name}"}
    end
  end

  defp handle_info(args) do
    path = Map.fetch!(args, "path")
    RagexImage.info(path)
  end

  defp handle_resize(args) do
    path = Map.fetch!(args, "path")
    opts = map_to_opts(args, [:output_path, :scale, :width, :height, :crop, :quality])
    RagexImage.resize(path, opts)
  end

  defp handle_crop(args) do
    path = Map.fetch!(args, "path")
    opts = map_to_opts(args, [:output_path, :left, :top, :width, :height, :auto_trim, :quality])
    RagexImage.crop(path, opts)
  end

  defp handle_rotate(args) do
    path = Map.fetch!(args, "path")
    opts = map_to_opts(args, [:output_path, :angle, :flip, :autorotate, :quality])
    RagexImage.rotate(path, opts)
  end

  defp handle_convert(args) do
    path = Map.fetch!(args, "path")
    output_path = Map.fetch!(args, "output_path")
    opts = map_to_opts(args, [:quality, :strip_metadata])
    RagexImage.convert(path, output_path, opts)
  end

  defp handle_apply_filter(args) do
    path = Map.fetch!(args, "path")
    filter = Map.fetch!(args, "filter")
    opts = map_to_opts(args, [:output_path, :sigma, :factor, :quality])
    RagexImage.apply_filter(path, filter, opts)
  end

  defp handle_composite(args) do
    base_path = Map.fetch!(args, "base_path")
    overlay_path = Map.fetch!(args, "overlay_path")
    output_path = Map.fetch!(args, "output_path")
    opts = map_to_opts(args, [:x, :y, :opacity, :quality])
    RagexImage.composite(base_path, overlay_path, output_path, opts)
  end

  defp handle_compare(args) do
    img_a = Map.fetch!(args, "image_a_path")
    img_b = Map.fetch!(args, "image_b_path")
    opts = map_to_opts(args, [:diff_output_path])
    RagexImage.compare(img_a, img_b, opts)
  end

  defp handle_avatar(args) do
    path = Map.fetch!(args, "path")
    output_path = Map.fetch!(args, "output_path")
    opts = map_to_opts(args, [:size, :shape, :quality])
    RagexImage.avatar(path, output_path, opts)
  end

  defp handle_draw_text(args) do
    path = Map.fetch!(args, "path")
    output_path = Map.fetch!(args, "output_path")
    text = Map.fetch!(args, "text")
    opts = map_to_opts(args, [:x, :y, :font_size, :text_color, :background_color, :quality])
    RagexImage.draw_text(path, output_path, text, opts)
  end

  defp map_to_opts(map, keys) do
    Enum.reduce(keys, [], fn key, acc ->
      str_key = Atom.to_string(key)

      if Map.has_key?(map, str_key) do
        val = Map.get(map, str_key)

        val =
          if key in [:crop, :flip, :shape] and is_binary(val), do: String.to_atom(val), else: val

        [{key, val} | acc]
      else
        acc
      end
    end)
  end
end
