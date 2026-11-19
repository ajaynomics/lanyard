require "test_helper"

# What an agent's computer image installs (Dockerfile.agent). A Sprite made
# again from the image keeps only these, so a tool an agent checks documents
# with must be here, not added by hand. bin/check-computer-image runs each in
# a built image (agent/test/computer-image-check.mjs).
class ComputerImageTest < ActiveSupport::TestCase
  DOCUMENT_PACKAGES = %w[ poppler-utils tesseract-ocr tesseract-ocr-data-eng unzip 7zip qpdf mupdf-tools diffutils libreoffice-writer python3 ].freeze

  test "the computer image installs every tool an agent checks a document with" do
    installed = Rails.root.join("Dockerfile.agent").read[/^RUN apk add --no-cache (.*?)&&/m, 1].to_s.split(/[\s\\]+/)

    assert_empty DOCUMENT_PACKAGES - installed, "Dockerfile.agent's apk add is missing these"
  end

  test "the image check runs each document tool as the agent" do
    check = Rails.root.join("agent/test/computer-image-check.mjs").read

    commands = [ "pdftoppm -v", "pdftotext -v", "tesseract --list-langs", "unzip -v", "python3 --version", "'7z'",
      "qpdf --version", "mutool -v", "diff --version", "soffice", "force_zip64" ]

    assert_empty commands.reject { check.include?(it) }, "agent/test/computer-image-check.mjs does not run these"
  end
end
