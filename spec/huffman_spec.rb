require "helper"

describe HTTP2::Header::Huffman do
  context "encode" do
    before(:all) { @encoder = HTTP2::Header::Huffman.new }
    [# input, expected
      ["www.example.com", "e7cf9bebe89b6fb16fa9b6ff"],
      ["no-cache",        "b9b9949556bf"],
      ["Mon, 21 Oct 2013 20:13:21 GMT", "d6dbb29884de2a718805062098513109b56ba3"],
    ].each do |input, expected|
      it "should encode #{input} into #{expected}" do
        @encoder.encode(input).unpack("H*").first.should eq expected
      end
    end
  end

end

