#desc "Generate Huffman precompiled tables"
#task :generate_table do
#end

module HuffmanTable
  BITS_AT_ONCE = 4
  EOS = 256

  class Node
    attr_accessor :next, :emit, :final
    attr_accessor :transitions
    attr_accessor :id
    @@id = 0
    def initialize
      @next = [nil, nil]
      @id = @@id
      @@id += 1
      @final = false
    end
    def add(code, len, chr)
      chr == EOS and self.final = true
      if len == 0
        @emit = chr
      else
        bit = (code & (1 << (len - 1))) == 0 ? 0 : 1
        node = @next[bit] ||= Node.new
        node.add(code, len - 1, chr)
      end
    end

    class Transition
      attr_accessor :emit, :node
      def initialize(emit, node)
        @emit = emit
        @node = node
      end
    end

    def self.generate_tree
      @root = new
      CODES.each_with_index do |c, chr|
        code, len = c
        @root.add(code, len, chr)
      end
      @root
    end

    def self.generate_machine
      generate_tree
      togo = Set[@root]
      @states = Set[@root]

      until togo.empty?
        node = togo.first
        togo.delete(node)

        next if node.transitions
        node.transitions = Array[1 << BITS_AT_ONCE]

        (1 << BITS_AT_ONCE).times do |input|
          n = node
          emit = ''
          (BITS_AT_ONCE - 1).downto(0) do |i|
            bit = (input & (1 << i)) == 0 ? 0 : 1
            n = n.next[bit]
            if n.emit
              emit << n.emit.chr('binary') unless n.emit == EOS
              n = @root
            end
          end
          node.transitions[input] = Transition.new(emit, n)
          togo << n
          @states << n
        end
      end
      puts "#{@states.size} states"
      @root
    end

    def self.root
      @root
    end

    def self.decode(input, len)
      emit = ''
      n = root
      nibbles = input.unpack("C*").flat_map{|b| [((b & 0xf0) >> 4), b & 0xf]}
      while emit.size < len && nibbles.size > 0
        nb = nibbles.shift
        t = n.transitions[nb]
        emit << t.emit
        n = t.node
      end
      unless emit.size == len && n.final && nibbles.all?{|x| x == 0xf}
        puts "len = #{emit.size} n.final = #{n.final} nibbles = #{nibbles}"
      end
      emit
    end
  end

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
    [      0x6,  5],
    [   0x1ffc, 13],
    [    0x1f0,  9],
    [   0x3ffc, 14],
    [   0x7ffc, 15],
    [     0x1e,  6],
    [     0x64,  7],
    [   0x1ffd, 13],
    [    0x3fa, 10],
    [    0x1f1,  9],
    [    0x3fb, 10],
    [    0x3fc, 10],
    [     0x65,  7],
    [     0x66,  7],
    [     0x1f,  6],
    [      0x7,  5],
    [      0x0,  4],
    [      0x1,  4],
    [      0x2,  4],
    [      0x8,  5],
    [     0x20,  6],
    [     0x21,  6],
    [     0x22,  6],
    [     0x23,  6],
    [     0x24,  6],
    [     0x25,  6],
    [     0x26,  6],
    [     0xec,  8],
    [  0x1fffc, 17],
    [     0x27,  6],
    [   0x7ffd, 15],
    [    0x3fd, 10],
    [   0x7ffe, 15],
    [     0x67,  7],
    [     0xed,  8],
    [     0xee,  8],
    [     0x68,  7],
    [     0xef,  8],
    [     0x69,  7],
    [     0x6a,  7],
    [    0x1f2,  9],
    [     0xf0,  8],
    [    0x1f3,  9],
    [    0x1f4,  9],
    [    0x1f5,  9],
    [     0x6b,  7],
    [     0x6c,  7],
    [     0xf1,  8],
    [     0xf2,  8],
    [    0x1f6,  9],
    [    0x1f7,  9],
    [     0x6d,  7],
    [     0x28,  6],
    [     0xf3,  8],
    [    0x1f8,  9],
    [    0x1f9,  9],
    [     0xf4,  8],
    [    0x1fa,  9],
    [    0x1fb,  9],
    [    0x7fc, 11],
    [0x3ffffda, 26],
    [    0x7fd, 11],
    [   0x3ffd, 14],
    [     0x6e,  7],
    [  0x3fffe, 18],
    [      0x9,  5],
    [     0x6f,  7],
    [      0xa,  5],
    [     0x29,  6],
    [      0xb,  5],
    [     0x70,  7],
    [     0x2a,  6],
    [     0x2b,  6],
    [      0xc,  5],
    [     0xf5,  8],
    [     0xf6,  8],
    [     0x2c,  6],
    [     0x2d,  6],
    [     0x2e,  6],
    [      0xd,  5],
    [     0x2f,  6],
    [    0x1fc,  9],
    [     0x30,  6],
    [     0x31,  6],
    [      0xe,  5],
    [     0x71,  7],
    [     0x72,  7],
    [     0x73,  7],
    [     0x74,  7],
    [     0x75,  7],
    [     0xf7,  8],
    [  0x1fffd, 17],
    [    0xffc, 12],
    [  0x1fffe, 17],
    [    0xffd, 12],
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
