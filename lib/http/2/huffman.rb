require_relative 'error'

module HTTP2

  # Implementation of huffman encoding for HPACK
  #
  # - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-07
  module Header

    # Huffman encoder/decoder
    class Huffman
      include Error

      BINARY = "binary"
      EOS = 256
      private_constant :BINARY, :EOS

      # Encodes provided value via huffman encoding.
      # Length is not encoded in this method.
      #
      # @param str [String]
      # @return [String] binary string
      def encode(str)
        str = str.dup.force_encoding(BINARY)
        index = 0
        emit = ''
        buffer = 0
        bits_in_buffer = 0

        while index < str.size
          code, length = CODES[str[index].ord]
          index += 1
          buffer = (buffer << length) | code
          bits_in_buffer += length
          while bits_in_buffer > 8
            bits_in_buffer -= 8
            masked = (buffer & (255 << bits_in_buffer))
            emit << (masked >> bits_in_buffer).chr(BINARY)
            buffer ^= masked
          end
        end
        if bits_in_buffer > 0
          emit << (
            (buffer << (8 - bits_in_buffer)) |
            ((1 << (8 - bits_in_buffer)) - 1)
            ).chr(BINARY)
        end

        emit
      end

      # Decodes provided Huffman coded string.
      # Decoding stops when decoded +len+ characters or +buf+ exhausted.
      #
      # @param buf [Buffer]
      # @param len [Integer]
      # @return [String] binary string
      def decode(buf, len)
        emit = ''
        state = 0 # start state
        nibbles = []
        while emit.bytesize < len
          if nibbles.empty?
            buf.empty? and raise CompressionError.new('Huffman decode error (too short)')
            c = buf.getbyte
            # Assume BITS_AT_ONCE == 4
            nibbles = [ (c & 0xf0) >> 4, c & 0xf ]
          end
          nb = nibbles.shift
          trans = MACHINE[state][1][nb]
          trans.first == EOS and raise CompressionError.new('Huffman decode error (EOS found)')
          emit << trans.first
          state = trans.last
        end
        unless MACHINE[state][0] && nibbles.all?{|x| x == 0xf}
          raise CompressionError.new('Huffman decode error (EOS invalid)')
        end
        emit.force_encoding(BINARY)
      end

      # Huffman table as specified in
      # - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-07#appendix-C
      CODES = [
        [0x3ffffba, 26],
        [0x3ffffbb, 26],
        [0x3ffffbc, 26],
        [0x3ffffbd, 26],
        [0x3ffffbe, 26],
        [0x3ffffbf, 26],
        [0x3ffffc0, 26],
        [0x3ffffc1, 26],
        [0x3ffffc2, 26],
        [0x3ffffc3, 26],
        [0x3ffffc4, 26],
        [0x3ffffc5, 26],
        [0x3ffffc6, 26],
        [0x3ffffc7, 26],
        [0x3ffffc8, 26],
        [0x3ffffc9, 26],
        [0x3ffffca, 26],
        [0x3ffffcb, 26],
        [0x3ffffcc, 26],
        [0x3ffffcd, 26],
        [0x3ffffce, 26],
        [0x3ffffcf, 26],
        [0x3ffffd0, 26],
        [0x3ffffd1, 26],
        [0x3ffffd2, 26],
        [0x3ffffd3, 26],
        [0x3ffffd4, 26],
        [0x3ffffd5, 26],
        [0x3ffffd6, 26],
        [0x3ffffd7, 26],
        [0x3ffffd8, 26],
        [0x3ffffd9, 26],
        [0x6,       5],
        [0x1ffc,    13],
        [0x1f0,     9],
        [0x3ffc,    14],
        [0x7ffc,    15],
        [0x1e,      6],
        [0x64,      7],
        [0x1ffd,    13],
        [0x3fa,     10],
        [0x1f1,     9],
        [0x3fb,     10],
        [0x3fc,     10],
        [0x65,      7],
        [0x66,      7],
        [0x1f,      6],
        [0x7,       5],
        [0x0,       4],
        [0x1,       4],
        [0x2,       4],
        [0x8,       5],
        [0x20,      6],
        [0x21,      6],
        [0x22,      6],
        [0x23,      6],
        [0x24,      6],
        [0x25,      6],
        [0x26,      6],
        [0xec,      8],
        [0x1fffc,   17],
        [0x27,      6],
        [0x7ffd,    15],
        [0x3fd,     10],
        [0x7ffe,    15],
        [0x67,      7],
        [0xed,      8],
        [0xee,      8],
        [0x68,      7],
        [0xef,      8],
        [0x69,      7],
        [0x6a,      7],
        [0x1f2,     9],
        [0xf0,      8],
        [0x1f3,     9],
        [0x1f4,     9],
        [0x1f5,     9],
        [0x6b,      7],
        [0x6c,      7],
        [0xf1,      8],
        [0xf2,      8],
        [0x1f6,     9],
        [0x1f7,     9],
        [0x6d,      7],
        [0x28,      6],
        [0xf3,      8],
        [0x1f8,     9],
        [0x1f9,     9],
        [0xf4,      8],
        [0x1fa,     9],
        [0x1fb,     9],
        [0x7fc,     11],
        [0x3ffffda, 26],
        [0x7fd,     11],
        [0x3ffd,    14],
        [0x6e,      7],
        [0x3fffe,   18],
        [0x9,       5],
        [0x6f,      7],
        [0xa,       5],
        [0x29,      6],
        [0xb,       5],
        [0x70,      7],
        [0x2a,      6],
        [0x2b,      6],
        [0xc,       5],
        [0xf5,      8],
        [0xf6,      8],
        [0x2c,      6],
        [0x2d,      6],
        [0x2e,      6],
        [0xd,       5],
        [0x2f,      6],
        [0x1fc,     9],
        [0x30,      6],
        [0x31,      6],
        [0xe,       5],
        [0x71,      7],
        [0x72,      7],
        [0x73,      7],
        [0x74,      7],
        [0x75,      7],
        [0xf7,      8],
        [0x1fffd,   17],
        [0xffc,     12],
        [0x1fffe,   17],
        [0xffd,     12],
        [0x3ffffdb, 26],
        [0x3ffffdc, 26],
        [0x3ffffdd, 26],
        [0x3ffffde, 26],
        [0x3ffffdf, 26],
        [0x3ffffe0, 26],
        [0x3ffffe1, 26],
        [0x3ffffe2, 26],
        [0x3ffffe3, 26],
        [0x3ffffe4, 26],
        [0x3ffffe5, 26],
        [0x3ffffe6, 26],
        [0x3ffffe7, 26],
        [0x3ffffe8, 26],
        [0x3ffffe9, 26],
        [0x3ffffea, 26],
        [0x3ffffeb, 26],
        [0x3ffffec, 26],
        [0x3ffffed, 26],
        [0x3ffffee, 26],
        [0x3ffffef, 26],
        [0x3fffff0, 26],
        [0x3fffff1, 26],
        [0x3fffff2, 26],
        [0x3fffff3, 26],
        [0x3fffff4, 26],
        [0x3fffff5, 26],
        [0x3fffff6, 26],
        [0x3fffff7, 26],
        [0x3fffff8, 26],
        [0x3fffff9, 26],
        [0x3fffffa, 26],
        [0x3fffffb, 26],
        [0x3fffffc, 26],
        [0x3fffffd, 26],
        [0x3fffffe, 26],
        [0x3ffffff, 26],
        [0x1ffff80, 25],
        [0x1ffff81, 25],
        [0x1ffff82, 25],
        [0x1ffff83, 25],
        [0x1ffff84, 25],
        [0x1ffff85, 25],
        [0x1ffff86, 25],
        [0x1ffff87, 25],
        [0x1ffff88, 25],
        [0x1ffff89, 25],
        [0x1ffff8a, 25],
        [0x1ffff8b, 25],
        [0x1ffff8c, 25],
        [0x1ffff8d, 25],
        [0x1ffff8e, 25],
        [0x1ffff8f, 25],
        [0x1ffff90, 25],
        [0x1ffff91, 25],
        [0x1ffff92, 25],
        [0x1ffff93, 25],
        [0x1ffff94, 25],
        [0x1ffff95, 25],
        [0x1ffff96, 25],
        [0x1ffff97, 25],
        [0x1ffff98, 25],
        [0x1ffff99, 25],
        [0x1ffff9a, 25],
        [0x1ffff9b, 25],
        [0x1ffff9c, 25],
        [0x1ffff9d, 25],
        [0x1ffff9e, 25],
        [0x1ffff9f, 25],
        [0x1ffffa0, 25],
        [0x1ffffa1, 25],
        [0x1ffffa2, 25],
        [0x1ffffa3, 25],
        [0x1ffffa4, 25],
        [0x1ffffa5, 25],
        [0x1ffffa6, 25],
        [0x1ffffa7, 25],
        [0x1ffffa8, 25],
        [0x1ffffa9, 25],
        [0x1ffffaa, 25],
        [0x1ffffab, 25],
        [0x1ffffac, 25],
        [0x1ffffad, 25],
        [0x1ffffae, 25],
        [0x1ffffaf, 25],
        [0x1ffffb0, 25],
        [0x1ffffb1, 25],
        [0x1ffffb2, 25],
        [0x1ffffb3, 25],
        [0x1ffffb4, 25],
        [0x1ffffb5, 25],
        [0x1ffffb6, 25],
        [0x1ffffb7, 25],
        [0x1ffffb8, 25],
        [0x1ffffb9, 25],
        [0x1ffffba, 25],
        [0x1ffffbb, 25],
        [0x1ffffbc, 25],
        [0x1ffffbd, 25],
        [0x1ffffbe, 25],
        [0x1ffffbf, 25],
        [0x1ffffc0, 25],
        [0x1ffffc1, 25],
        [0x1ffffc2, 25],
        [0x1ffffc3, 25],
        [0x1ffffc4, 25],
        [0x1ffffc5, 25],
        [0x1ffffc6, 25],
        [0x1ffffc7, 25],
        [0x1ffffc8, 25],
        [0x1ffffc9, 25],
        [0x1ffffca, 25],
        [0x1ffffcb, 25],
        [0x1ffffcc, 25],
        [0x1ffffcd, 25],
        [0x1ffffce, 25],
        [0x1ffffcf, 25],
        [0x1ffffd0, 25],
        [0x1ffffd1, 25],
        [0x1ffffd2, 25],
        [0x1ffffd3, 25],
        [0x1ffffd4, 25],
        [0x1ffffd5, 25],
        [0x1ffffd6, 25],
        [0x1ffffd7, 25],
        [0x1ffffd8, 25],
        [0x1ffffd9, 25],
        [0x1ffffda, 25],
        [0x1ffffdb, 25],
        [0x1ffffdc, 25],
      ]

    end

  end

end
