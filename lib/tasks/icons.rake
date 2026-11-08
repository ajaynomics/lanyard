# The greyscale masks Icon lays the accent under, drawn from Icon#svg. Run it
# after changing the drawing; it needs rsvg-convert and ImageMagick, which the
# app's image does not.
namespace :icons do
  desc "Draw the icon's masks into lib/durable_assistants/icon"
  task masks: :environment do
    require "tmpdir"
    icon = Icon.new(0)
    Dir.mktmpdir do |dir|
      Icon::VARIANTS.each do |name, (size, full_bleed)|
        { "tile" => icon.svg(full_bleed:, tile_top: "#fff", tile_bottom: "#fff", bubble: "#fff", dots: "#fff"),
          "glyph" => icon.svg(full_bleed:, tile_top: "#000", tile_bottom: "#000", bubble: "#fff", dots: "#000") }.each do |kind, svg|
          File.write("#{dir}/#{kind}.svg", svg)
          system("rsvg-convert", "-w", size.to_s, "-h", size.to_s, "#{dir}/#{kind}.svg", "-o", "#{dir}/#{kind}.png", exception: true)
          # The tile is its shape (alpha); the glyph is how white each pixel is.
          channel = kind == "tile" ? %w[ -alpha extract ] : %w[ -background black -alpha remove -colorspace gray ]
          system("magick", "#{dir}/#{kind}.png", *channel, "-depth", "8", "-define", "png:color-type=0",
            "-strip", Icon::MASKS.join("#{name}-#{kind}.png").to_s, exception: true)
        end
      end
    end
  end
end
