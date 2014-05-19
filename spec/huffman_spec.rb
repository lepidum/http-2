require "helper"

describe HTTP2::Header::Huffman do
  huffman_examples = [# plain, encoded
      ["www.example.com", "e7cf9bebe89b6fb16fa9b6ff"],
      ["no-cache",        "b9b9949556bf"],
      ["Mon, 21 Oct 2013 20:13:21 GMT", "d6dbb29884de2a718805062098513109b56ba3"],
    ]
  context "encode" do
    before(:all) { @encoder = HTTP2::Header::Huffman.new }
      huffman_examples.each do |plain, encoded|
      it "should encode #{plain} into #{encoded}" do
        @encoder.encode(plain).unpack("H*").first.should eq encoded
      end
    end
  end
  context "decode" do
    before(:all) { @encoder = HTTP2::Header::Huffman.new }
    huffman_examples.each do |plain, encoded|
      it "should decode #{encoded} into #{plain}" do
        @encoder.decode(HTTP2::Buffer.new([encoded].pack("H*")), plain.bytesize).should eq plain
      end
      
      [
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.8; rv:16.0) Gecko/20100101 Firefox/16.0",
        "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "http://www.craigslist.org/about/sites/",
        "cl_b=AB2BKbsl4hGM7M4nH5PYWghTM5A; cl_def_lang=en; cl_def_hp=shoals",
        "image/png,image/*;q=0.8,*/*;q=0.5",
        "BX=c99r6jp89a7no&b=3&s=q4; localization=en-us%3Bus%3Bus",
        "UTF-8でエンコードした日本語文字列",
      ].each do |string|
        it "should encode then decode '#{string}' into the same" do
          s = string.dup.force_encoding('binary')
          encoded = @encoder.encode(s)
          @encoder.decode(HTTP2::Buffer.new(encoded),
                          s.bytesize).should eq s
        end
      end
    end

    it "should leave excessive bytes in the buffer" do
      plain, encoded = huffman_examples[0]
      encoded = [encoded].pack("H*")
      excessive = "abc".force_encoding('binary')
      buffer = HTTP2::Buffer.new(encoded + excessive)
      expect { @encoder.decode(buffer, plain.bytesize) }.not_to raise_error
      buffer.should == excessive
    end

    it "should raise when input is shorter than expected" do
      plain, encoded = huffman_examples[0]
      encoded = [encoded].pack("H*")
      expect { @encoder.decode(HTTP2::Buffer.new(encoded[0...-1]), plain.bytesize) }.to raise_error(/short/)
    end
    it "should raise when input is not padded by 1s" do
      plain, encoded = ["www.example.com", "e7cf9bebe89b6fb16fa9b6fe"] # note the fe at end
      encoded = [encoded].pack("H*")
      expect { @encoder.decode(HTTP2::Buffer.new(encoded), plain.bytesize) }.to raise_error(/EOS/)
    end
  end
end

