require "zlib"

# The app's icon in the install's accent (APP__ACCENT_HUE): a white speech
# bubble with three dots on a tile of the accent, as Messages' icon is green.
# The vector is drawn here; the PNGs a phone and a browser need are the
# accent laid under two greyscale masks drawn from the same vector once
# (bin/rails icons:masks, kept in lib/durable_assistants/icon), so an image
# with no image library still has an icon in any hue. Made once per process.
class Icon
  # name => [ pixels, full bleed ]: a phone rounds a full-bleed icon itself.
  VARIANTS = {
    "favicon" => [ 32, false ], "app-192" => [ 192, false ], "app" => [ 512, false ],
    "apple-touch" => [ 180, true ], "maskable" => [ 512, true ]
  }.freeze
  MASKS = Rails.root.join("lib/durable_assistants/icon")

  def self.for(hue) = (@icons ||= {})[hue] ||= new(hue)

  attr_reader :hue

  def initialize(hue)
    @hue = hue
    @pngs = {}
  end

  def svg(full_bleed: false, tile_top: hex(TOP), tile_bottom: hex(BOTTOM), bubble: "#fff", dots: hex(BOTTOM))
    glyph = full_bleed ? %(<g transform="translate(64 64) scale(.75)">) : "<g>"
    <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
        <defs><linearGradient id="tile" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#{tile_top}"/><stop offset="1" stop-color="#{tile_bottom}"/></linearGradient></defs>
        <rect width="512" height="512" rx="#{full_bleed ? 0 : 115}" fill="url(#tile)"/>
        #{glyph}
          <rect x="96" y="132" width="320" height="224" rx="112" fill="#{bubble}"/>
          <path d="M156 318c4 44-16 74-52 94 54 4 98-14 128-48z" fill="#{bubble}"/>
          <circle cx="190" cy="244" r="26" fill="#{dots}"/>
          <circle cx="256" cy="244" r="26" fill="#{dots}" fill-opacity=".7"/>
          <circle cx="322" cy="244" r="26" fill="#{dots}" fill-opacity=".4"/>
        </g>
      </svg>
    SVG
  end

  def png(variant)
    @pngs[variant] ||= begin
      size, = VARIANTS.fetch(variant)
      tile, glyph = %w[ tile glyph ].map { self.class.mask("#{variant}-#{it}", size).bytes }
      top, bottom = rgb(TOP), rgb(BOTTOM)
      Png.encode(size, size) do |y|
        colour = top.zip(bottom).map { |from, to| from + (to - from) * y / (size - 1.0) }
        (y * size...(y + 1) * size).flat_map do |index|
          white = glyph[index] / 255.0
          [ *colour.map { (it + (255 - it) * white).round }, tile[index] ]
        end
      end
    end
  end

  # A favicon.ico holding the 32px PNG, which every browser reads.
  def ico
    png = png("favicon")
    [ 0, 1, 1 ].pack("v3") + [ 32, 32, 0, 0, 1, 32, png.bytesize, 22 ].pack("C4v2V2") + png
  end

  def self.mask(name, size)
    (@masks ||= {})[name] ||= Png.decode_grey(MASKS.join("#{name}.png").binread, size)
  end

  private
    # The tile's lightness, top to bottom; its chroma and hue are the accent's.
    TOP = 0.62
    BOTTOM = 0.5
    CHROMA = 0.19

    def hex(lightness) = format("#%02x%02x%02x", *rgb(lightness))

    # oklch to sRGB, the chroma lowered until the colour fits, as a browser does.
    def rgb(lightness, chroma = CHROMA)
      a, b = chroma * Math.cos(hue * Math::PI / 180), chroma * Math.sin(hue * Math::PI / 180)
      l = (lightness + 0.3963377774 * a + 0.2158037573 * b)**3
      m = (lightness - 0.1055613458 * a - 0.0638541728 * b)**3
      s = (lightness - 0.0894841775 * a - 1.2914855480 * b)**3
      linear = [ 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                 -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                 -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s ]
      return rgb(lightness, chroma - 0.005) if chroma > 0 && linear.any? { it < -0.0005 || it > 1.0005 }
      linear.map { (255 * (it <= 0.0031308 ? 12.92 * it : 1.055 * it.clamp(0, 1)**(1 / 2.4) - 0.055)).round.clamp(0, 255) }
    end

  # The little of PNG this needs: write RGBA, read the masks' 8-bit grey.
  module Png
    SIGNATURE = "\x89PNG\r\n\x1a\n".b

    # The block gives a row's RGBA bytes.
    def self.encode(width, height)
      rows = Array.new(height) { |y| [ 0, *yield(y) ].pack("C*") }.join
      SIGNATURE + chunk("IHDR", [ width, height, 8, 6, 0, 0, 0 ].pack("N2C5")) + chunk("IDAT", Zlib.deflate(rows, 9)) + chunk("IEND", "")
    end

    def self.decode_grey(data, size)
      raise ArgumentError, "not a PNG" unless data.start_with?(SIGNATURE)
      header, idat, at = nil, +"".b, 8
      while at < data.bytesize
        length, type = data.byteslice(at, 8).unpack("Na4")
        body = data.byteslice(at + 8, length)
        header = body.unpack("N2C5") if type == "IHDR"
        idat << body if type == "IDAT"
        at += 12 + length
      end
      raise ArgumentError, "mask is not #{size}px 8-bit grey" unless header.first(4) == [ size, size, 8, 0 ] && header.last == 0
      raw, previous = Zlib.inflate(idat), Array.new(size, 0)
      (0...size).map do |y|
        filter, *bytes = raw.byteslice(y * (size + 1), size + 1).bytes
        previous = unfilter(filter, bytes, previous)
        previous.pack("C*")
      end.join
    end

    # One byte a pixel, so "left" is the byte before.
    def self.unfilter(filter, bytes, up)
      bytes.each_index.with_object([]) do |x, row|
        left, corner = x.zero? ? [ 0, 0 ] : [ row[x - 1], up[x - 1] ]
        predicted = case filter
        when 0 then 0
        when 1 then left
        when 2 then up[x]
        when 3 then (left + up[x]) / 2
        when 4 then paeth(left, up[x], corner)
        else raise ArgumentError, "unknown PNG filter #{filter}"
        end
        row << ((bytes[x] + predicted) & 0xff)
      end
    end

    def self.paeth(left, up, corner)
      estimate = left + up - corner
      [ left, up, corner ].min_by.with_index { |value, index| [ (estimate - value).abs, index ] }
    end

    def self.chunk(type, body) = [ body.bytesize ].pack("N") + type + body + [ Zlib.crc32(type + body) ].pack("N")
  end
end
