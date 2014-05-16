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
  context "encode2" do
    before(:all) { @encoder = HTTP2::Header::Huffman.new }
    [# input, expected
      ["www.example.com", "e7cf9bebe89b6fb16fa9b6ff"],
      ["no-cache",        "b9b9949556bf"],
      ["Mon, 21 Oct 2013 20:13:21 GMT", "d6dbb29884de2a718805062098513109b56ba3"],
    ].each do |input, expected|
      it "should encode #{input} into #{expected}" do
        @encoder.encode2(input).unpack("H*").first.should eq expected
      end
    end
  end

  context "Encode builder shift" do
    before(:all) { @encoder = HTTP2::Header::Huffman.new }
    [# code, l, s, res
      [0x5,  4, 0, [0x50]], # 0101
      [0x5,  4, 1, [0x28]],
      [0x5,  4, 2, [0x14]],
      [0x5,  4, 3, [0x0a]],
      [0x5,  4, 4, [0x05]],
      [0x5,  4, 5, [0x02, 0x80]],
      [0x5,  4, 6, [0x01, 0x40]],
      [0x5,  4, 7, [0x00, 0xa0]],
      [0x5,  4, 8, [0x00, 0x50]],
      [0x55, 8, 0, [0x55]], # 01010101
      [0x123, 9, 0, [0x91, 0x80]], # 100100011
      [0x123, 9, 1, [0x48, 0xc0]],
      [0x123, 9, 2, [0x24, 0x60]],
      [0x123, 9, 3, [0x12, 0x30]],
      [0x123, 9, 4, [0x09, 0x18]],
      [0x123, 9, 5, [0x04, 0x8c]],
      [0x123, 9, 6, [0x02, 0x46]],
      [0x123, 9, 7, [0x01, 0x23]],
    ].each do |code, length, shift, expected|
      it "shift(#{code}, #{length}, #{shift}) should eq #{expected}" do
        @encoder.shift(code, length, shift). should eq expected
      end
    end
  end
end

