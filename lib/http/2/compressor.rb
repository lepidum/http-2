module HTTP2

  # Implementation of header compression for HTTP 2.0 (HPACK) format adapted
  # to efficiently represent HTTP headers in the context of HTTP 2.0.
  #
  # - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-07
  module Header

    # The set of components used to encode or decode a header set form an
    # encoding context: an encoding context contains a header table and a
    # reference set - there is one encoding context for each direction.
    #
    class EncodingContext
      include Error

      # TODO: replace StringIO with Buffer...

      # Static table
      # - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-07#appendix-B
      STATIC_TABLE = [
        [':authority',                  ''            ],
        [':method',                     'GET'         ],
        [':method',                     'POST'        ],
        [':path',                       '/'           ],
        [':path',                       '/index.html' ],
        [':scheme',                     'http'        ],
        [':scheme',                     'https'       ],
        [':status',                     '200'         ],
        [':status',                     '204'         ],
        [':status',                     '206'         ],
        [':status',                     '304'         ],
        [':status',                     '400'         ],
        [':status',                     '404'         ],
        [':status',                     '500'         ],
        ['accept-charset',              ''            ],
        ['accept-encoding',             ''            ],
        ['accept-language',             ''            ],
        ['accept-ranges',               ''            ],
        ['accept',                      ''            ],
        ['access-control-allow-origin', ''            ],
        ['age',                         ''            ],
        ['allow',                       ''            ],
        ['authorization',               ''            ],
        ['cache-control',               ''            ],
        ['content-disposition',         ''            ],
        ['content-encoding',            ''            ],
        ['content-language',            ''            ],
        ['content-length',              ''            ],
        ['content-location',            ''            ],
        ['content-range',               ''            ],
        ['content-type',                ''            ],
        ['cookie',                      ''            ],
        ['date',                        ''            ],
        ['etag',                        ''            ],
        ['expect',                      ''            ],
        ['expires',                     ''            ],
        ['from',                        ''            ],
        ['host',                        ''            ],
        ['if-match',                    ''            ],
        ['if-modified-since',           ''            ],
        ['if-none-match',               ''            ],
        ['if-range',                    ''            ],
        ['if-unmodified-since',         ''            ],
        ['last-modified',               ''            ],
        ['link',                        ''            ],
        ['location',                    ''            ],
        ['max-forwards',                ''            ],
        ['proxy-authenticate',          ''            ],
        ['proxy-authorization',         ''            ],
        ['range',                       ''            ],
        ['referer',                     ''            ],
        ['refresh',                     ''            ],
        ['retry-after',                 ''            ],
        ['server',                      ''            ],
        ['set-cookie',                  ''            ],
        ['strict-transport-security',   ''            ],
        ['transfer-encoding',           ''            ],
        ['user-agent',                  ''            ],
        ['vary',                        ''            ],
        ['via',                         ''            ],
        ['www-authenticate',            ''            ],
      ].freeze

      # Current table of header key-value pairs.
      attr_reader :table

      # Current reference set
      # [index, flag]
      attr_reader :refset

      # Initializes compression context with appropriate client/server
      # defaults and maximum size of the header table.
      #
      # @param type [Symbol] either :request or :response
      # @param limit [Integer] maximum header table size in bytes
      # @param options [Hash] encoding options
      #   :no_huffman       => true    Do not use Huffman encodings
      #   :no_index         => true    Do not use incremental indexing
      #   :no_reference_set => true    Do not use reference set differencing
      def initialize(type, limit = 4096, options = {})
        @type = type
        @table = []
        @limit = limit
        @refset = []
        @options = options
      end

      # Predefined options set for ease
      # http://mew.org/~kazu/material/2014-hpack.pdf
      Naive   = { no_index: true, no_reference_set: true, no_huffman: true }.freeze
      NaiveH  = { no_index: true, no_reference_set: true,                  }.freeze
      Linear  = {                 no_reference_set: true, no_huffman: true }.freeze
      LinearH = {                 no_reference_set: true,                  }.freeze
      Diff    = {                                         no_huffman: true }.freeze
      DiffH   = {                                                          }.freeze

      # Finds an entry in current header table by index.
      # Note that index is zero-based in this module.
      #
      # If the index is greater than the last index in the header table,
      # an entry in the static table is dereferenced.
      #
      # If the index is greater than the last static index, an error is raised.
      #
      # @param index [Integer] zero-based index in the header table.
      # @return [Array] [key, value, static?]
      def dereference(index)
        if index >= @table.size
          index -= @table.size
          if index >= STATIC_TABLE.size
            raise CompressionError.new("Index too large")
          else
            [*STATIC_TABLE[index], true]
          end
        else
          [*@table[index], false]
        end
      end

      # Performs differential coding based on provided command type.
      # - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-07#section-3.2.1
      #
      # @param cmd [Hash] { type:, name:, value:, index: }
      # @return [Hash] emitted header
      def process(cmd)
        emit = nil

        case cmd[:type]
        when :refsetempty
          # empty refset
          @refset.clear

        when :changetablesize
          # TODO: implement
          @limit = cmd[:name]
          size_check(nil)
          # TODO: expect and verify refset emptying on next

        when :indexed
          # Indexed Representation
          # An _indexed representation_ corresponding to an entry _present_ in
          # the reference set entails the following actions:
          # o The entry is removed from the reference set.

          idx = cmd[:name]
          cur = @refset.find_index {|i,_| i == idx}

          if cur
            @refset.delete_at(cur)
          else
            # An _indexed representation_ corresponding to an entry _not present_
            # in the reference set entails the following actions:
            k, v, static = dereference(idx)
            emit = [k, v]

            if static
              # o  If referencing an element of the static table:
              #    *  The header field corresponding to the referenced entry is
              #       emitted.
              #    *  The referenced static entry is inserted at the beginning of the
              #       header table.
              #    *  A reference to this new header table entry is added to the
              #       reference set, except if this new entry didn't fit in the
              #       header table.
              idx = add_to_table(emit)
              idx and @refset.push [idx]
            else
              # o  If referencing an element of the header table:
              #    *  The header field corresponding to the referenced entry is
              #       emitted.
              #    *  The referenced header table entry is added to the reference
              #       set.
              @refset.push [idx]
            end
          end

        else
          # A literal representation that is not added to the header table
          # entails the following action:
          #  - The header is emitted.
          #
          # A literal representation that is added to the header table entails
          # the following actions:
          #  - The header is emitted.
          #  - The header is added to the header table, at the location
          #    defined by the representation.
          #  - The new entry is added to the reference set.
          #
          if cmd[:name].is_a? Integer
            k, v, _ = dereference(cmd[:name])

            cmd[:index] ||= cmd[:name]
            cmd[:value] ||= v
            cmd[:name] = k
          end

          emit = [cmd[:name], cmd[:value]]

          if cmd[:type] == :incremental
            idx = add_to_table(emit)
            idx and @refset.push [idx]
          end
        end

        emit
      end

      # Emits best available command to encode provided header.
      #
      # @param header [Hash]
      def addcmd(header)
        # check if we have an exact match in header table
        if idx = @table.index(header)
          if !active? idx
            return { name: idx, type: :indexed }
          end
        end

        # check if we have a partial match on header name
        if idx = @table.index {|(k,_)| k == header.first}
          # default to incremental indexing
          cmd = { name: idx, value: header.last, type: :incremental}

          # TODO: implement literal without indexing strategy

          return cmd
        end

        return { name: header.first, value: header.last, type: :incremental }
      end

      # Emits command to remove current index from working set.
      #
      # @param idx [Integer]
      def removecmd(idx)
        {name: idx, type: :indexed}
      end

      private

      # Add a name-value pair to the header table.
      # Older entries might have been evicted so that
      # the new entry fits in the header table.
      # Indices in the refset is kept in sync.
      #
      # @param cmd [Array] [name, value]
      # @return [Integer] index of thenewly added entry or nil if not added
      def add_to_table(cmd)
        if size_check(cmd)
          @table.unshift(cmd)
          @refset.each_index {|i| @refset[i][0] += 1}
          0
        else
          nil
        end
      end

      # To keep the header table size lower than or equal to @limit,
      # remove one or more entries at the end of the header table.
      #
      # @param cmd [Hash]
      # @return [Boolean]
      def size_check(cmd)
        cursize = @table.join.bytesize + @table.size * 32
        cmdsize = cmd.nil? ? 0 : cmd.join.bytesize + 32

        # The addition of a new entry with a size greater than the
        # SETTINGS_HEADER_TABLE_SIZE limit causes all the entries from the
        # header table to be dropped and the new entry not to be added to the
        # header table.  The replacement of an existing entry with a new entry
        # with a size greater than the SETTINGS_HEADER_TABLE_SIZE has the same
        # consequences.
        # TODO: check whether this still holds in HPACK-07
        if cmdsize > @limit
          @table.clear
          return false
        end

        cur = 0
        while (cursize + cmdsize) > @limit do
          last_index = @table.size - 1
          e = @table.pop

          # Whenever an entry is evicted from the header table, any reference to
          # that entry contained by the reference set is removed.
          @refset.delete_if {|i,_| i == last_index }

          cursize -= (e.join.bytesize + 32)
        end

        return true
      end

      def active?(idx)
        !@refset.find {|i,_| i == idx }.nil?
      end
    end

    # Header representation as defined by the spec.
    HEADREP = {
      indexed:      {prefix: 7, pattern: 0x80},
      incremental:  {prefix: 6, pattern: 0x40},
      noindex:      {prefix: 4, pattern: 0x00},
      neverindexed: {prefix: 4, pattern: 0x10},
      refsetempty:  {prefix: 0, pattern: 0x30},
      changetablesize: {prefix: 4, pattern: 0x20},
    }

    # Responsible for encoding header key-value pairs using HPACK algorithm.
    # Compressor must be initialized with appropriate starting context based
    # on local role: client or server.
    #
    # @example
    #   client_role = Compressor.new(:request)
    #   server_role = Compressor.new(:response)
    # @param type [Symbol] either :request or :response
    class Compressor
      def initialize(type, options = {})
        @cc = EncodingContext.new(type, options)
        @options = options
      end

      # Encodes provided value via integer representation.
      # - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-07#section-4.1.1
      #
      #  If I < 2^N - 1, encode I on N bits
      #  Else
      #      encode 2^N - 1 on N bits
      #      I = I - (2^N - 1)
      #      While I >= 128
      #           Encode (I % 128 + 128) on 8 bits
      #           I = I / 128
      #      encode (I) on 8 bits
      #
      # @param i [Integer] value to encode
      # @param n [Integer] number of available bits
      # @return [String] binary string
      def integer(i, n)
        limit = 2**n - 1
        return [i].pack('C') if (i < limit)

        bytes = []
        bytes.push limit if !n.zero?

        i -= limit
        while (i >= 128) do
          bytes.push((i % 128) + 128)
          i = i / 128
        end

        bytes.push i
        bytes.pack('C*')
      end

      # Encodes provided value via string literal representation.
      # - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-07#section-4.1.2
      #
      # * The string length, defined as the number of bytes needed to store
      #   its UTF-8 representation, is represented as an integer with a seven
      #   bits prefix. If the string length is strictly less than 127, it is
      #   represented as one byte.
      # * If the bit 7 of the first byte is 1, the string value is represented
      #   as a list of Huffman encoded octets
      #   (padded with bit 1's until next octet boundary).
      # * If the bit 7 of the first byte is 0, the string value is
      #   represented as a list of UTF-8 encoded octets.
      #
      # @param str [String]
      # @return [String] binary string
      def string(str)
        if @options[:no_huffman]
          integer(str.bytesize, 7) << str.dup.force_encoding('binary')
        else
          bytes = integer(str.bytesize, 7) << Huffman.new.encode(str)
          bytes.setbyte(0, bytes[0].unpack("C").first | 0x80)
          bytes
        end
      end

      # Encodes header command with appropriate header representation.
      # - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-07#section-4
      #
      # @param h [Hash] header command
      # @param buffer [String]
      def header(h, buffer = Buffer.new)
        rep = HEADREP[h[:type]]

        if h[:type] == :indexed
          buffer << integer(h[:name]+1, rep[:prefix])

        else
          if h[:name].is_a? Integer
            buffer << integer(h[:name]+1, rep[:prefix])
          else
            buffer << integer(0, rep[:prefix])
            buffer << string(h[:name])
          end

          buffer << string(h[:value])
        end

        # set header representation pattern on first byte
        fb = buffer[0].unpack("C").first | rep[:pattern]
        buffer.setbyte(0, fb)

        buffer
      end

      # Encodes provided list of HTTP headers.
      #
      # @param headers [Hash]
      # @return [Buffer]
      def encode(headers)
        buffer = Buffer.new
        commands = []

        # Literal header names MUST be translated to lowercase before
        # encoding and transmission.
        headers.map! {|(hk,hv)| [hk.downcase, hv] }

        if @options[:no_reference_set]
          # Debugging mode.  Do not use refset at all.
          unless @cc.refset.empty?
            commands.push(type: :changetablesize)
          end
          headers.each do |(hk,hv)|
            cmd = @cc.addcmd [hk, hv]
            if cmd[:type] == :incremental
              cmd[:type] = :noindex
            end
            commands.push cmd
          end
        else
          # Reference set differenciating

          # Generate remove commands for missing headers
          @cc.refset.each do |idx, (wk,wv)|
            if headers.find {|(hk,hv)| hk == wk && hv == wv }.nil?
              commands.push @cc.removecmd idx
            end
          end

          # Generate add commands for new headers
          headers.each do |(hk,hv)|
            if @cc.refset.find {|i,(wk,wv)| hk == wk && hv == wv}.nil?
              commands.push @cc.addcmd [hk, hv]
            end
          end

        end

        commands.each do |cmd|
          @cc.process cmd.dup
          buffer << header(cmd)
        end

        buffer
      end
    end

    # Responsible for decoding received headers and maintaining compression
    # context of the opposing peer. Decompressor must be initialized with
    # appropriate starting context based on local role: client or server.
    #
    # @example
    #   server_role = Decompressor.new(:request)
    #   client_role = Decompressor.new(:response)
    class Decompressor
      def initialize(type)
        @cc = EncodingContext.new(type)
      end

      # Decodes integer value from provided buffer.
      #
      # @param buf [String]
      # @param n [Integer] number of available bits
      def integer(buf, n)
        limit = 2**n - 1
        i = !n.zero? ? (buf.getbyte & limit) : 0

        m = 0
        while byte = buf.getbyte do
          i += ((byte & 127) << m)
          m += 7

          break if (byte & 128).zero?
        end if (i == limit)

        i
      end

      # Decodes string value from provided buffer.
      #
      # @param buf [String]
      # @return [String] UTF-8 encoded string
      def string(buf)
        huff = (buf.readbyte(0) & 0x80) == 0x80
        len = integer(buf, 7)
        if huff
          Huffman.new.decode(buf, len).force_encoding('utf-8')
        else
          buf.read(len).force_encoding('utf-8')
        end
      end

      # Decodes header command from provided buffer.
      #
      # @param buf [Buffer]
      def header(buf)
        peek = buf.readbyte(0)

        header = {}
        header[:type], type = HEADREP.select do |t, desc|
          mask = (peek >> desc[:prefix]) << desc[:prefix]
          mask == desc[:pattern]
        end.first

        header[:type] or raise CompressionError

        header[:name] = integer(buf, type[:prefix])

        case header[:type]
        when :indexed
          header[:name] == 0 and raise CompressionError.new
          header[:name] -= 1
        when :changetablesize, :refsetempty
        else
          if header[:name] == 0
            header[:name] = string(buf)
          else
            header[:name] -= 1
          end
          header[:value] = string(buf)
        end

        header
      end

      # Decodes and processes header commands within provided buffer.
      #
      # Once all the representations contained in a header block have been
      # processed, the headers that are in common with the previous header
      # set are emitted, during the reference set emission.
      #
      # For the reference set emission, each header contained in the
      # reference set that has not been emitted during the processing of the
      # header block is emitted.
      #
      # - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-03#section-3.2.2
      #
      # @param buf [Buffer]
      # @return [Array] set of HTTP headers
      def decode(buf)
        set = []
        set << @cc.process(header(buf)) while !buf.empty?
        @cc.refset.each do |i,header|
          set << header if !set.include? header
        end

        set.compact
      end
    end

  end
end
