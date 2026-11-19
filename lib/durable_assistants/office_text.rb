module DurableAssistants
  # The words in a Word, Excel or PowerPoint file, read from the XML inside
  # its zip: a document's paragraphs, a workbook's first sheet as tab-separated
  # rows, each slide's paragraphs in order. Formatting, tables' shape, charts
  # and pictures are left behind. nil when the file isn't one, is damaged, or
  # a part would unpack past PART_LIMIT (a zip can claim to hold far more
  # than it weighs).
  module OfficeText
    PART_LIMIT = 20.megabytes

    def self.of(path, kind)
      Zip::File.open(path) do |zip|
        case kind
        when "docx" then paragraphs(xml(zip, "word/document.xml"), "p", "t")
        when "xlsx" then sheet(zip)
        when "pptx" then slides(zip)
        end
      end
    rescue Zip::Error, Nokogiri::XML::SyntaxError, TooBig
      nil
    end

    class TooBig < StandardError; end

    def self.xml(zip, name)
      entry = zip.find_entry(name) or return
      raise TooBig if entry.size > PART_LIMIT
      Nokogiri::XML(entry.get_input_stream.read, &:strict).remove_namespaces!
    end

    def self.paragraphs(doc, paragraph, run)
      doc&.css(paragraph)&.map { it.css(run).map(&:text).join }&.join("\n")
    end

    def self.sheet(zip)
      shared = xml(zip, "xl/sharedStrings.xml")&.css("si")&.map { it.css("t").map(&:text).join } || []
      xml(zip, "xl/worksheets/sheet1.xml")&.css("sheetData row")&.map do |row|
        row.css("c").map do |cell|
          case cell["t"]
          when "s" then shared[cell.at_css("v")&.text.to_i]
          when "inlineStr" then cell.css("is t").map(&:text).join
          else cell.at_css("v")&.text
          end
        end.join("\t")
      end&.join("\n")
    end

    def self.slides(zip)
      names = zip.glob("ppt/slides/slide*.xml").map(&:name).sort_by { it[/\d+/].to_i }
      names.each.with_index(1).map { |name, number| "Slide #{number}\n#{paragraphs(xml(zip, name), "p", "t")}" }.join("\n\n")
    end
  end
end
