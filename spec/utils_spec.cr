require "./spec_helper"

describe Crystalline::Utils do
  describe ".file_uri" do
    it "leaves an ordinary path untouched" do
      Crystalline::Utils.file_uri("/tmp/plain_path/file.cr").should eq("file:///tmp/plain_path/file.cr")
    end

    it "percent-encodes a path so it matches the uri a client sends" do
      # An unencoded uri never matches the one the editor sent for the same
      # file, and every lookup keyed by uri - diagnostics, document versions -
      # silently misses.
      uri = Crystalline::Utils.file_uri("/tmp/my dir/файл.cr")
      uri.should eq("file:///tmp/my%20dir/%D1%84%D0%B0%D0%B9%D0%BB.cr")
      URI.parse(uri).decoded_path.should eq("/tmp/my dir/файл.cr")
    end

    it "accepts a Path" do
      Crystalline::Utils.file_uri(Path["/tmp/a b.cr"]).should eq("file:///tmp/a%20b.cr")
    end
  end
end
