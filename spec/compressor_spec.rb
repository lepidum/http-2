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

  context "decode" do
    spec_examples = [
      { title: "D.3. Request Examples without Huffman",
        type: :request,
        table_size: 4096,
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
        streams: [
          { wire: "8287 8644 8ce7 cf9b ebe8 9b6f b16f a9b6 ff",
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
          { wire: "5c86 b9b9 9495 56bf",
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
          { wire: "3085 8c8b 8440 8857 1c5c db73 7b2f af89
                   571c 5cdb 7372 4d9c 57",
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
        table_size: 256,
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
        table_size: 256,
        streams: [
          { wire: "4882 4017 5985 bf06 724b 9763 93d6 dbb2
                   9884 de2a 7188 0506 2098 5131 09b5 6ba3
                   7197 adce bf19 8e7e 7cf9 bebe 89b6 fb16
                   fa9b 6f",
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
          { wire: "8484 4393 d6db b298 84de 2a71 8805 0620
                   9851 3111 b56b a35e 84ab dd97 ff84 8483
                   837b b1e0 d6cf 9f6e 8f9f d3e5 f6fa 76fe
                   fd3c 7edf 9eff 1f2f 0f3c fe9f 6fcf 7f8f
                   879f 61ad 4f4c c9a9 73a2 200e c372 5e18
                   b1b7 4e3f",
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

  context "encode and decode" do
    before { pending "Not yet implemented" }
    # http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-01#appendix-B

    before (:all) do
     @cc = Compressor.new(:request)
     @dc = Decompressor.new(:request)
    end

    E1_BYTES = [
      0x44, # (literal header with incremental indexing, name index = 3)
      0x16, # (header value string length = 22)
      "/my-example/index.html".bytes,
      0x4C, # (literal header with incremental indexing, name index = 11)
      0x0D, # (header value string length = 13)
      "my-user-agent".bytes,
      0x40, # (literal header with incremental indexing, new name)
      0x0B, # (header name string length = 11)
      "mynewheader".bytes,
      0x05, # (header value string length = 5)
      "first".bytes
    ].flatten

    E1_HEADERS = [
      [":path", "/my-example/index.html"],
      ["user-agent", "my-user-agent"],
      ["mynewheader", "first"]
    ]

    it "should match first header set in spec appendix" do
      @cc.encode(E1_HEADERS).bytes.should eq E1_BYTES
    end

    it "should decode first header set in spec appendix" do
      @dc.decode(Buffer.new(E1_BYTES.pack("C*"))).should eq E1_HEADERS
    end

    E2_BYTES = [
      0x9e, # (indexed header, index = 30: removal from reference set)
      0xa0, # (indexed header, index = 32: removal from reference set)
      0x04, # (literal header, substitution indexing, name index = 3)
      0x1e, # (replaced entry index = 30)
      0x1f, # (header value string length = 31)
      "/my-example/resources/script.js".bytes,
      0x5f,
      0x02, # (literal header, incremental indexing, name index = 32)
      0x06, # (header value string length = 6)
      "second".bytes
    ].flatten

    E2_HEADERS = [
      [":path", "/my-example/resources/script.js"],
      ["user-agent", "my-user-agent"],
      ["mynewheader", "second"]
    ]

    it "should match second header set in spec appendix" do
      # Force incremental indexing, the spec doesn't specify any strategy
      # for deciding when to use incremental vs substitution indexing, and
      # early implementations defer to incremental by default:
      # - https://github.com/sludin/http2-perl/blob/master/lib/HTTP2/Draft/Compress.pm#L157
      # - https://github.com/MSOpenTech/http2-katana/blob/master/Shared/SharedProtocol/Compression/HeadersDeltaCompression/CompressionProcessor.cs#L259
      # - https://hg.mozilla.org/try/file/9d9a29992e4d/netwerk/protocol/http/Http2CompressionDraft00.cpp#l636
      #
      e2bytes = E2_BYTES.dup
      e2bytes[2] = 0x44     # incremental indexing, name index = 3
      e2bytes.delete_at(3)  # remove replacement index byte

      @cc.encode(E2_HEADERS).bytes.should eq e2bytes
    end

    it "should decode second header set in spec appendix" do
      @dc.decode(Buffer.new(E2_BYTES.pack("C*"))).should match_array E2_HEADERS
    end

    it "encode-decode should be invariant" do
      cc = Compressor.new(:request)
      dc = Decompressor.new(:request)

      E1_HEADERS.should match_array dc.decode(cc.encode(E1_HEADERS))
      E2_HEADERS.should match_array dc.decode(cc.encode(E2_HEADERS))
    end

    it "should encode-decode request set of headers" do
      cc = Compressor.new(:request)
      dc = Decompressor.new(:request)

      req = [
        [":method", "get"],
        [":host", "localhost"],
        [":path", "/resource"],
        ["accept", "*/*"]
      ]

      dc.decode(cc.encode(req)).should eq req
    end

    it "should downcase all request header names" do
      cc = Compressor.new(:request)
      dc = Decompressor.new(:request)

      req = [["Accept", "IMAGE/PNG"]]
      recv = dc.decode(cc.encode(req))
      recv.should eq [["accept", "IMAGE/PNG"]]
    end
  end
end
