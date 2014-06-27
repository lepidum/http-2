module HTTP2

  # Performs encoding, decoding, and validation of binary HTTP 2.0 frames.
  #
  class Framer
    include Error

    # Maximum frame size (16383 bytes)
    MAX_PAYLOAD_SIZE = 2**14-1

    # Maximum stream ID (2^31)
    MAX_STREAM_ID = 0x7fffffff

    # Maximum window increment value (2^31)
    MAX_WINDOWINC = 0x7fffffff

    # HTTP 2.0 frame type mapping as defined by the spec
    FRAME_TYPES = {
      data:          0x0,
      headers:       0x1,
      priority:      0x2,
      rst_stream:    0x3,
      settings:      0x4,
      push_promise:  0x5,
      ping:          0x6,
      goaway:        0x7,
      window_update: 0x8,
      continuation:  0x9,
      altsvc:        0xa,
      blocked:       0xb,
    }

    FRAME_TYPES_WITH_PADDING = [ :data, :headers, :push_promise ]

    # Per frame flags as defined by the spec
    FRAME_FLAGS = {
      data: {
        end_stream:  0, end_segment: 1,
        padded: 3, compressed: 5
      },
      headers: {
        end_stream:  0, end_segment: 1, end_headers: 2,
        padded: 3, priority: 5,
      },
      priority:     {},
      rst_stream:   {},
      settings:     { ack: 0 },
      push_promise: {
        end_headers: 2,
        padded: 3,
      },
      ping:         { ack: 0 },
      goaway:       {},
      window_update:{},
      continuation: { end_headers: 2 },
      altsvc: {},
      blocked: {},
    }

    # Default settings as defined by the spec
    DEFINED_SETTINGS = {
      settings_header_table_size:      1,
      settings_enable_push:            2,
      settings_max_concurrent_streams: 3,
      settings_initial_window_size:    4,
      settings_compress_data:          5,
    }

    # Default error types as defined by the spec
    DEFINED_ERRORS = {
      no_error:           0,
      protocol_error:     1,
      internal_error:     2,
      flow_control_error: 3,
      settings_timeout:   4,
      stream_closed:      5,
      frame_size_error:   6,
      refused_stream:     7,
      cancel:             8,
      compression_error:  9,
      connect_error:      10,
      enhance_your_calm:  11,
      inadequate_security: 12,
    }

    RBIT  = 0x7fffffff
    RBYTE = 0x0fffffff
    EBIT  = 0x80000000
    UINT32 = "N".freeze
    UINT16 = "n".freeze
    UINT8  = "C".freeze
    HEADERPACK = (UINT16 + UINT8 + UINT8 + UINT32).freeze
    BINARY = 'binary'.freeze

    private_constant :RBIT, :RBYTE, :EBIT, :HEADERPACK, :UINT32, :UINT16, :UINT8, :BINARY

    # Generates common 8-byte frame header.
    # - http://tools.ietf.org/html/draft-ietf-httpbis-http2-04#section-4.1
    #
    # @param frame [Hash]
    # @return [String]
    def commonHeader(frame)
      header = []

      if !FRAME_TYPES[frame[:type]]
        raise CompressionError.new("Invalid frame type (#{frame[:type]})")
      end

      if frame[:length] > MAX_PAYLOAD_SIZE
        raise CompressionError.new("Frame size is too large: #{frame[:length]}")
      end

      if frame[:stream] > MAX_STREAM_ID
        raise CompressionError.new("Stream ID (#{frame[:stream]}) is too large")
      end

      if frame[:type] == :window_update && frame[:increment] > MAX_WINDOWINC
        raise CompressionError.new("Window increment (#{frame[:increment]}) is too large")
      end

      header << frame[:length]
      header << FRAME_TYPES[frame[:type]]
      header << frame[:flags].reduce(0) do |acc, f|
        position = FRAME_FLAGS[frame[:type]][f]
        if !position
          raise CompressionError.new("Invalid frame flag (#{f}) for #{frame[:type]}")
        end

        acc |= (1 << position)
        acc
      end

      header << frame[:stream]
      header.pack(HEADERPACK) # 16,8,8,32
    end

    # Decodes common 8-byte header.
    #
    # @param buf [Buffer]
    def readCommonHeader(buf)
      frame = {}
      frame[:length], type, flags, stream = buf.slice(0,8).unpack(HEADERPACK)

      frame[:type], _ = FRAME_TYPES.select { |t,pos| type == pos }.first
      if frame[:type]
        frame[:flags] = FRAME_FLAGS[frame[:type]].reduce([]) do |acc, (name, pos)|
          acc << name if (flags & (1 << pos)) > 0
          acc
        end
      end

      frame[:stream] = stream & RBIT
      frame
    end

    # Generates encoded HTTP 2.0 frame.
    # - http://tools.ietf.org/html/draft-ietf-httpbis-http2
    #
    # @param frame [Hash]
    def generate(frame)
      bytes  = Buffer.new
      length = 0

      frame[:flags]  ||= []
      frame[:stream] ||= 0

      case frame[:type]
      when :data
        bytes  << frame[:payload]
        length += frame[:payload].bytesize

      when :headers
        if frame[:priority]
          frame[:flags] += [:priority] if !frame[:flags].include? :priority
        end

        if frame[:flags].include? :priority
          bytes << [(frame[:exclusive] ? EBIT : 0) |
                    (frame[:stream_dependency] & RBIT)].pack(UINT32)
          bytes << [frame[:weight] - 1].pack(UINT8)
          length += 5
        end

        bytes  << frame[:payload]
        length += frame[:payload].bytesize

      when :priority
        bytes << [(frame[:exclusive] ? EBIT : 0) |
                  (frame[:stream_dependency] & RBIT)].pack(UINT32)
        bytes << [frame[:weight] - 1].pack(UINT8)
        length += 5

      when :rst_stream
        bytes  << pack_error(frame[:error])
        length += 4

      when :settings
        if frame[:stream] != 0
          raise CompressionError.new("Invalid stream ID (#{frame[:stream]})")
        end

        frame[:payload].each do |(k,v)|
          if k.is_a? Integer
            DEFINED_SETTINGS.has_value?(k) or next
          else
            k = DEFINED_SETTINGS[k]

            if k.nil?
              raise CompressionError.new("Unknown settings ID for #{k}")
            end
          end

          bytes  << [k].pack(UINT16)
          bytes  << [v].pack(UINT32)
          length += 6
        end

      when :push_promise
        bytes  << [frame[:promise_stream] & RBIT].pack(UINT32)
        bytes  << frame[:payload]
        length += 4 + frame[:payload].bytesize

      when :ping
        if frame[:payload].bytesize != 8
          raise CompressionError.new("Invalid payload size \
                                    (#{frame[:payload].size} != 8 bytes)")
        end
        bytes  << frame[:payload]
        length += 8

      when :goaway
        bytes  << [frame[:last_stream] & RBIT].pack(UINT32)
        bytes  << pack_error(frame[:error])
        length += 8

        if frame[:payload]
          bytes  << frame[:payload]
          length += frame[:payload].bytesize
        end

      when :window_update
        bytes  << [frame[:increment] & RBIT].pack(UINT32)
        length += 4

      when :continuation
        bytes  << frame[:payload]
        length += frame[:payload].bytesize

      when :altsvc
        bytes << [frame[:max_age], frame[:port]].pack(UINT32 + UINT16)
        length += 6
        if frame[:proto]
          frame[:proto].bytesize > 255 and raise CompressionError.new("Proto too long")
          bytes << [frame[:proto].bytesize].pack(UINT8) << frame[:proto].force_encoding(BINARY)
          length += 1 + frame[:proto].bytesize
        else
          bytes << [0].pack(UINT8)
          length += 1
        end
        if frame[:host]
          frame[:host].bytesize > 255 and raise CompressionError.new("Host too long")
          bytes << [frame[:host].bytesize].pack(UINT8) << frame[:host].force_encoding(BINARY)
          length += 1 + frame[:host].bytesize
        else
          bytes << [0].pack(UINT8)
          length += 1
        end
        if frame[:origin]
          bytes << frame[:origin]
          length += frame[:origin].bytesize
        end

      when :blocked
        # no flags, no payload
      end

      # Process padding.
      #  frame[:padding] gives number of extra octets to be added.
      # - http://tools.ietf.org/html/draft-ietf-httpbis-http2-12#section-6.1
      if frame[:padding]
        unless FRAME_TYPES_WITH_PADDING.include?(frame[:type])
          raise CompressionError.new("Invalid padding flag for #{frame[:type]}")
        end

        padlen = frame[:padding]
        padlen > 0 or raise CompressionError.new("Invalid padding #{padlen}")
        padlen + length > MAX_PAYLOAD_SIZE and raise CompressionError.new("Invalid padding #{padlen} too large")

        length += padlen
        if padlen > 256
          raise CompressionError.new("Padding too long (#{padlen})")
        else
          bytes.prepend([padlen -= 1].pack(UINT8))
          frame[:flags] << :padded
        end
        # Padding:  Padding octets that contain no application semantic value.
        # Padding octets MUST be set to zero when sending and ignored when
        # receiving.
        bytes << "\0" * padlen
      end

      frame[:length] = length
      bytes.prepend(commonHeader(frame))
    end

    # Decodes complete HTTP 2.0 frame from provided buffer. If the buffer
    # does not contain enough data, no further work is performed.
    #
    # @param buf [Buffer]
    def parse(buf)
      return nil if buf.size < 8
      frame = readCommonHeader(buf)
      return nil if buf.size < 8 + frame[:length]

      buf.read(8)
      payload = buf.read(frame[:length])

      # Implementations MUST discard frames
      # that have unknown or unsupported types.
      # - http://tools.ietf.org/html/draft-ietf-httpbis-http2-13#section-5.5
      return nil if frame[:type].nil?

      # Process padding
      padlen = 0
      if FRAME_TYPES_WITH_PADDING.include?(frame[:type])
        padded = frame[:flags].include?(:padded)
        if padded
          padlen = payload.read(1).unpack(UINT8).first
          frame[:padding] = padlen + 1
          padlen > payload.bytesize and raise ProtocolError.new("padding too long")
          padlen > 0 and payload.slice!(-padlen,padlen)
          frame[:length] -= frame[:padding]
          frame[:flags].delete(:padded)
        end
      end

      case frame[:type]
      when :data
        frame[:payload] = payload.read(frame[:length])
      when :headers
        if frame[:flags].include? :priority
          e_sd = payload.read_uint32
          frame[:stream_dependency] = e_sd & RBIT
          frame[:exclusive] = (e_sd & EBIT) != 0
          frame[:weight] = payload.getbyte + 1
        end
        frame[:payload] = payload.read(frame[:length])
      when :priority
        e_sd = payload.read_uint32
        frame[:stream_dependency] = e_sd & RBIT
        frame[:exclusive] = (e_sd & EBIT) != 0
        frame[:weight] = payload.getbyte + 1
      when :rst_stream
        frame[:error] = unpack_error payload.read_uint32

      when :settings
        # NOTE: frame[:length] might not match the number of frame[:payload]
        # because unknown extensions are ignored.
        frame[:payload] = []
        unless frame[:length] % 6 == 0
          raise ProtocolError.new("Invalid settings payload length")
        end

        if frame[:stream] != 0
          raise ProtocolError.new("Invalid stream ID (#{frame[:stream]})")
        end

        (frame[:length] / 6).times do
          id  = payload.read(2).unpack(UINT16).first
          val = payload.read_uint32

          # Unsupported or unrecognized settings MUST be ignored.
          # Here we send it along.
          name, _ = DEFINED_SETTINGS.select { |name, v| v == id }.first
          frame[:payload] << [name, val] if name
        end
      when :push_promise
        frame[:promise_stream] = payload.read_uint32 & RBIT
        frame[:payload] = payload.read(frame[:length])
      when :ping
        frame[:payload] = payload.read(frame[:length])
      when :goaway
        frame[:last_stream] = payload.read_uint32 & RBIT
        frame[:error] = unpack_error payload.read_uint32

        size = frame[:length] - 8
        frame[:payload] = payload.read(size) if size > 0
      when :window_update
        frame[:increment] = payload.read_uint32 & RBIT
      when :continuation
        frame[:payload] = payload.read(frame[:length])
      when :altsvc
        frame[:max_age], frame[:port] = payload.read(6).unpack(UINT32 + UINT16)

        len = payload.getbyte
        len > 0 and frame[:proto] = payload.read(len)

        len = payload.getbyte
        len > 0 and frame[:host] = payload.read(len)

        if payload.size > 0
          frame[:origin] = payload.read(payload.size)
        end
      when :blocked
        # no flags, no payload
      else
        # Unknown frame type is explicitly allowed
      end

      frame
    end

    private

    def pack_error(e)
      if !e.is_a? Integer
        if DEFINED_ERRORS[e].nil?
          raise CompressionError.new("Unknown error ID for #{e}")
        end

        e = DEFINED_ERRORS[e]
      end

      [e].pack(UINT32)
    end

    def unpack_error(e)
      name, _ = DEFINED_ERRORS.select { |name, v| v == e }.first
      name || error
    end

  end
end
