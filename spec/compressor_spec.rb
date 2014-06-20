require "helper"

describe HTTP2::Header do

  let(:c) { Compressor.new :request }
  let(:d) { Decompressor.new :response }

  context "literal representation" do
    context "integer" do
      it "should encode 10 using a 5-bit prefix" do
        buf = c.integer(10, 5)
        buf.should eq [10].pack('C')
        d.integer(Buffer.new(buf), 5).should eq 10
      end

      it "should encode 10 using a 0-bit prefix" do
        buf = c.integer(10, 0)
        buf.should eq [10].pack('C')
        d.integer(Buffer.new(buf), 0).should eq 10
      end

      it "should encode 1337 using a 5-bit prefix" do
        buf = c.integer(1337, 5)
        buf.should eq [31,128+26,10].pack('C*')
        d.integer(Buffer.new(buf), 5).should eq 1337
      end

      it "should encode 1337 using a 0-bit prefix" do
        buf = c.integer(1337,0)
        buf.should eq [128+57,10].pack('C*')
        d.integer(Buffer.new(buf), 0).should eq 1337
      end
    end

    context "string" do
      [ ['with huffman',    :always, 0x80 ],
        ['without huffman', :never,  0] ].each do |desc, option, msb|
        let (:trailer) { "trailer" }

        [
          ['ascii codepoints', 'abcdefghij'],
          ['utf-8 codepoints', 'éáűőúöüó€'],
          ['long utf-8 strings', 'éáűőúöüó€'*100],
        ].each do |datatype, plain|
          it "should handle #{datatype} #{desc}" do
            # NOTE: don't put this new in before{} because of test case shuffling
            @c = Compressor.new(:request, huffman: option)
            str = @c.string(plain)
            (str.getbyte(0) & 0x80).should eq msb

            buf = Buffer.new(str + trailer)
            d.string(buf).should eq plain
            buf.should eq trailer
          end
        end
      end
      context "choosing shorter representation" do
        [ ['日本語', :plain],
          ['200', :huffman],
          ['xq', :plain],   # prefer plain if equal size
        ].each do |string, choice|
          before { @c = Compressor.new(:request, huffman: :shorter) }

          it "should return #{choice} representation" do
            wire = @c.string(string)
            (wire.getbyte(0) & 0x80).should eq (choice == :plain ? 0 : 0x80)
          end
        end
      end
    end
  end

  context "header representation" do
    it "should handle indexed representation" do
      h = {name: 10, type: :indexed}
      wire = c.header(h)
      (wire.readbyte(0) & 0x80).should eq 0x80
      (wire.readbyte(0) & 0x7f).should eq h[:name] + 1
      d.header(wire).should eq h
    end
    it "should raise when decoding indexed representation with index zero" do
      h = {name: 10, type: :indexed}
      wire = c.header(h)
      wire[0] = 0x80.chr('binary')
      expect { d.header(wire) }.to raise_error CompressionError
    end

    context "literal w/o indexing representation" do
      it "should handle indexed header" do
        h = {name: 10, value: "my-value", type: :noindex}
        wire = c.header(h)
        (wire.readbyte(0) & 0xf0).should eq 0x0
        (wire.readbyte(0) & 0x0f).should eq h[:name] + 1
        d.header(wire).should eq h
      end

      it "should handle literal header" do
        h = {name: "x-custom", value: "my-value", type: :noindex}
        wire = c.header(h)
        (wire.readbyte(0) & 0xf0).should eq 0x0
        (wire.readbyte(0) & 0x0f).should eq 0
        d.header(wire).should eq h
      end
    end

    context "literal w/ incremental indexing" do
      it "should handle indexed header" do
        h = {name: 10, value: "my-value", type: :incremental}
        wire = c.header(h)
        (wire.readbyte(0) & 0xc0).should eq 0x40
        (wire.readbyte(0) & 0x3f).should eq h[:name] + 1
        d.header(wire).should eq h
      end

      it "should handle literal header" do
        h = {name: "x-custom", value: "my-value", type: :incremental}
        wire = c.header(h)
        (wire.readbyte(0) & 0xc0).should eq 0x40
        (wire.readbyte(0) & 0x3f).should eq 0
        d.header(wire).should eq h
      end
    end

    context "literal never indexed" do
      it "should handle indexed header" do
        h = {name: 10, value: "my-value", type: :neverindexed}
        wire = c.header(h)
        (wire.readbyte(0) & 0xf0).should eq 0x10
        (wire.readbyte(0) & 0x0f).should eq h[:name] + 1
        d.header(wire).should eq h
      end

      it "should handle literal header" do
        h = {name: "x-custom", value: "my-value", type: :neverindexed}
        wire = c.header(h)
        (wire.readbyte(0) & 0xf0).should eq 0x10
        (wire.readbyte(0) & 0x0f).should eq 0
        d.header(wire).should eq h
      end
    end
  end

  context "shared compression context" do
    before(:each) { @cc = EncodingContext.new(:request) }

    it "should be initialized with empty headers" do
      cc = EncodingContext.new(:request)
      cc.table.should be_empty

      cc = EncodingContext.new(:response)
      cc.table.should be_empty
    end

    it "should be initialized with empty working set" do
      @cc.refset.should be_empty
    end

    it "should update reference set based on prior state" do
      @cc.refset.should be_empty

      @cc.process({name: 6, type: :indexed})
      @cc.refset.should eq [[0, :emitted]]

      @cc.process({name: 6, type: :indexed})
      @cc.refset.should eq [[1, :emitted],[0, :emitted]]

      @cc.process({name: 0, type: :indexed})
      @cc.refset.should eq [[1, :emitted]]

      @cc.process({name: 1, type: :indexed})
      @cc.refset.should be_empty
    end

    context "processing" do
      it "should toggle index representation headers in working set" do
        @cc.process({name: 6, type: :indexed})
        @cc.refset.first.should eq [0, :emitted]

        @cc.process({name: 0, type: :indexed})
        @cc.refset.should be_empty
      end

      [ ["no indexing", :noindex],
        ["never indexed", :neverindexed]].each do |desc, type|
        context "#{desc}" do
          it "should process indexed header with literal value" do
            original_table = @cc.table.dup

            emit = @cc.process({name: 4, value: "/path", type: type})
            emit.should eq [":path", "/path"]
            @cc.refset.should be_empty
            @cc.table.should eq original_table
          end

          it "should process literal header with literal value" do
            original_table = @cc.table.dup

            emit = @cc.process({name: "x-custom", value: "random", type: type})
            emit.should eq ["x-custom", "random"]
            @cc.refset.should be_empty
            @cc.table.should eq original_table
          end
        end
      end

      context "incremental indexing" do
        it "should process indexed header with literal value" do
          original_table = @cc.table.dup

          emit = @cc.process({name: 4, value: "/path", type: :incremental})
          emit.should eq [":path", "/path"]
          @cc.refset.first.should eq [0, :emitted]
          (@cc.table - original_table).should eq [[":path", "/path"]]
        end

        it "should process literal header with literal value" do
          original_table = @cc.table.dup

          @cc.process({name: "x-custom", value: "random", type: :incremental})
          @cc.refset.first.should eq [0, :emitted]
          (@cc.table - original_table).should eq [["x-custom", "random"]]
        end
      end

      context "size bounds" do
        it "should drop headers from end of table" do
          cc = EncodingContext.new(:request, table_size: 2048)
          cc.instance_eval do
            add_to_table(["test1", "1" * 1024])
            add_to_table(["test2", "2" * 500])
          end

          original_table = cc.table.dup
          original_size = original_table.join.bytesize +
            original_table.size * 32

          cc.process({
                       name: "x-custom",
                       value: "a" * (2048 - original_size),
                       type: :incremental
                     })

          cc.table.first[0].should eq "x-custom"
          cc.table.size.should eq original_table.size # number of entries
        end
      end

      it "should clear table if entry exceeds table size" do
        cc = EncodingContext.new(:request, table_size: 2048)
        cc.instance_eval do
          add_to_table(["test1", "1" * 1024])
          add_to_table(["test2", "2" * 500])
        end

        h = { name: "x-custom", value: "a", index: 0, type: :incremental }
        e = { name: "large", value: "a" * 2048, index: 0}

        cc.process(h)
        cc.process(e.merge({type: :incremental}))
        cc.table.should be_empty
      end

      it "should shrink table if set smaller size" do
        cc = EncodingContext.new(:request, table_size: 2048)
        cc.instance_eval do
          add_to_table(["test1", "1" * 1024])
          add_to_table(["test2", "2" * 500])
        end

        cc.process({type: :changetablesize, name: 1500})
        cc.table.size.should be 1
        cc.table.first[0].should eq 'test2'
      end
    end
  end

  spec_examples = [
    { title: "D.3. Request Examples without Huffman",
      type: :request,
      table_size: 4096,
      huffman: :never,
      refset: :shorter,
      streams: [
        { wire: "8287 8644 0f77 7777 2e65 7861 6d70 6c65
                 2e63 6f6d",
          emitted: [
            [":method", "GET"],
            [":scheme", "http"],
            [":path", "/"],
            [":authority", "www.example.com"],
          ],
          table: [
            [":authority", "www.example.com"],
            [":path", "/"],
            [":scheme", "http"],
            [":method", "GET"],
          ],
          refset: [0,1,2,3],
        },
        { wire: "5c08 6e6f 2d63 6163 6865",
          emitted: [
            ["cache-control", "no-cache"],
            [":authority", "www.example.com"],
            [":path", "/"],
            [":scheme", "http"],
            [":method", "GET"],
          ],
          table: [
            ["cache-control", "no-cache"],
            [":authority", "www.example.com"],
            [":path", "/"],
            [":scheme", "http"],
            [":method", "GET"],
          ],
          refset: [0,1,2,3,4],
        },
        { wire: "3085 8c8b 8440 0a63 7573 746f 6d2d 6b65
                 790c 6375 7374 6f6d 2d76 616c 7565",
          emitted: [
            [":method", "GET"],
            [":scheme", "https"],
            [":path", "/index.html"],
            [":authority", "www.example.com"],
            ["custom-key", "custom-value"],
          ],
          table: [
            ["custom-key", "custom-value"],
            [":path", "/index.html"],
            [":scheme", "https"],
            ["cache-control", "no-cache"],
            [":authority", "www.example.com"],
            [":path", "/"],
            [":scheme", "http"],
            [":method", "GET"],
          ],
          refset: [0,1,2,4,7],
        }
      ],
    },
    { title: "D.4.  Request Examples with Huffman",
      type: :request,
      table_size: 4096,
      huffman: :always,
      refset: :shorter,
      streams: [
        { wire: "8287 8644 8cf1 e3c2 e5f2 3a6b a0ab 90f4 ff",
          emitted: [
            [":method", "GET"],
            [":scheme", "http"],
            [":path", "/"],
            [":authority", "www.example.com"],
          ],
          table: [
            [":authority", "www.example.com"],
            [":path", "/"],
            [":scheme", "http"],
            [":method", "GET"],
          ],
          refset: [0,1,2,3],
        },
        { wire: "5c86 a8eb 1064 9cbf",
          emitted: [
            ["cache-control", "no-cache"],
            [":authority", "www.example.com"],
            [":path", "/"],
            [":scheme", "http"],
            [":method", "GET"],
          ],
          table: [
            ["cache-control", "no-cache"],
            [":authority", "www.example.com"],
            [":path", "/"],
            [":scheme", "http"],
            [":method", "GET"],
          ],
          refset: [0,1,2,3,4],
        },
        { wire: "3085 8c8b 8440 8825 a849 e95b a97d 7f89
                 25a8 49e9 5bb8 e8b4 bf",
          emitted: [
            [":method", "GET"],
            [":scheme", "https"],
            [":path", "/index.html"],
            [":authority", "www.example.com"],
            ["custom-key", "custom-value"],
          ],
          table: [
            ["custom-key", "custom-value"],
            [":path", "/index.html"],
            [":scheme", "https"],
            ["cache-control", "no-cache"],
            [":authority", "www.example.com"],
            [":path", "/"],
            [":scheme", "http"],
            [":method", "GET"],
          ],
          refset: [0,1,2,4,7],
        },
      ],
    },
    { title: "D.5.  Response Examples without Huffman",
      type: :response,
      table_size: 256,
      huffman: :never,
      refset: :always,
      streams: [
        { wire: "4803 3330 3259 0770 7269 7661 7465 631d
                 4d6f 6e2c 2032 3120 4f63 7420 3230 3133
                 2032 303a 3133 3a32 3120 474d 5471 1768
                 7474 7073 3a2f 2f77 7777 2e65 7861 6d70
                 6c65 2e63 6f6d",
          emitted: [
            [":status", "302"],
            ["cache-control", "private"],
            ["date", "Mon, 21 Oct 2013 20:13:21 GMT"],
            ["location", "https://www.example.com"],
          ],
          table: [
            ["location", "https://www.example.com"],
            ["date", "Mon, 21 Oct 2013 20:13:21 GMT"],
            ["cache-control", "private"],
            [":status", "302"],
          ],
          refset: [0,1,2,3],
        },
        { wire: "8c",
          emitted: [
            [":status", "200"],
            ["location", "https://www.example.com"],
            ["date", "Mon, 21 Oct 2013 20:13:21 GMT"],
            ["cache-control", "private"],
          ],
          table: [
            [":status", "200"],
            ["location", "https://www.example.com"],
            ["date", "Mon, 21 Oct 2013 20:13:21 GMT"],
            ["cache-control", "private"],
          ],
          refset: [0,1,2,3],
        },
        { wire: "8484 431d 4d6f 6e2c 2032 3120 4f63 7420
                 3230 3133 2032 303a 3133 3a32 3220 474d
                 545e 0467 7a69 7084 8483 837b 3866 6f6f
                 3d41 5344 4a4b 4851 4b42 5a58 4f51 5745
                 4f50 4955 4158 5157 454f 4955 3b20 6d61
                 782d 6167 653d 3336 3030 3b20 7665 7273
                 696f 6e3d 31",
          emitted: [
            ["cache-control", "private"],
            ["date", "Mon, 21 Oct 2013 20:13:22 GMT"],
            ["content-encoding", "gzip"],
            ["location", "https://www.example.com"],
            [":status", "200"],
            ["set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"],
          ],
          table: [
            ["set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"],
            ["content-encoding", "gzip"],
            ["date", "Mon, 21 Oct 2013 20:13:22 GMT"],
          ],
          refset: [0,1,2],
        },
      ],
    },
    { title: "D.6.  Response Examples with Huffman",
      type: :response,
      table_size: 256,
      huffman: :always,
      refset: :always,
      streams: [
        { wire: "4882 6402 5985 aec3 771a 4b63 96d0 7abe
                 9410 54d4 44a8 2005 9504 0b81 66e0 82a6
                 2d1b ff71 919d 29ad 1718 63c7 8f0b 97c8
                 e9ae 82ae 43d3",
          emitted: [
            [":status", "302"],
            ["cache-control", "private"],
            ["date", "Mon, 21 Oct 2013 20:13:21 GMT"],
            ["location", "https://www.example.com"],
          ],
          table: [
            ["location", "https://www.example.com"],
            ["date", "Mon, 21 Oct 2013 20:13:21 GMT"],
            ["cache-control", "private"],
            [":status", "302"],
          ],
          refset: [0,1,2,3],
        },
        { wire: "8c",
          emitted: [
            [":status", "200"],
            ["location", "https://www.example.com"],
            ["date", "Mon, 21 Oct 2013 20:13:21 GMT"],
            ["cache-control", "private"],
          ],
          table: [
            [":status", "200"],
            ["location", "https://www.example.com"],
            ["date", "Mon, 21 Oct 2013 20:13:21 GMT"],
            ["cache-control", "private"],
          ],
          refset: [0,1,2,3],
        },
        { wire: "8484 4396 d07a be94 1054 d444 a820 0595
                 040b 8166 e084 a62d 1bff 5e83 9bd9 ab84
                 8483 837b ad94 e782 1dd7 f2e6 c7b3 35df
                 dfcd 5b39 60d5 af27 087f 3672 c1ab 270f
                 b529 1f95 8731 6065 c003 ed4e e5b1 063d
                 5007",
          emitted: [
            ["cache-control", "private"],
            ["date", "Mon, 21 Oct 2013 20:13:22 GMT"],
            ["content-encoding", "gzip"],
            ["location", "https://www.example.com"],
            [":status", "200"],
            ["set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"],
          ],
          table: [
            ["set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"],
            ["content-encoding", "gzip"],
            ["date", "Mon, 21 Oct 2013 20:13:22 GMT"],
          ],
          refset: [0,1,2],
        },
      ],
    },
  ]

  context "decode" do
    spec_examples.each do |ex|
      context "spec example #{ex[:title]}" do
        ex[:streams].size.times do |nth|
          context "request #{nth+1}" do
            before { @dc = Decompressor.new(ex[:type], table_size: ex[:table_size]) }
            before do
              (0...nth).each do |i|
                bytes = [ex[:streams][i][:wire].delete(" \n")].pack("H*")
                @dc.decode(HTTP2::Buffer.new(bytes))
              end
            end
            subject do
              bytes = [ex[:streams][nth][:wire].delete(" \n")].pack("H*")
              @emitted = @dc.decode(HTTP2::Buffer.new(bytes))
            end
            it "should emit expected headers" do
              subject
              Set[*@emitted].should eq Set[*ex[:streams][nth][:emitted]]
            end
            it "should update header table" do
              subject
              @dc.instance_eval{@cc.table}.should eq ex[:streams][nth][:table]
            end
            it "should update refset" do
              subject
              Set[*@dc.instance_eval{@cc.refset}.map{|r|r.first}].should eq \
              Set[*ex[:streams][nth][:refset]]
            end
          end
        end
      end
    end
  end

  context "encode" do
    spec_examples.each do |ex|
      context "spec example #{ex[:title]}" do
        ex[:streams].size.times do |nth|
          context "request #{nth+1}" do
            before { @cc = Compressor.new(ex[:type],
                                          table_size: ex[:table_size],
                                          huffman: ex[:huffman],
                                          refset: ex[:refset]) }
            before do
              (0...nth).each do |i|
                @cc.encode(ex[:streams][i][:emitted])
              end
            end
            subject do
              @cc.encode(ex[:streams][nth][:emitted])
            end
            it "should emit expected bytes on wire" do
              subject.unpack("H*").first.should eq ex[:streams][nth][:wire].delete(" \n")
            end
            it "should update header table" do
              subject
              @cc.instance_eval{@cc.table}.should eq ex[:streams][nth][:table]
            end
            it "should update refset" do
              subject
              Set[*@cc.instance_eval{@cc.refset}.map{|r|r.first}].should eq \
              Set[*ex[:streams][nth][:refset]]
            end
          end
        end
      end
    end
  end

end
