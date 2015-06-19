require_relative 'helper'

options = { port: 8080 }
OptionParser.new do |opts|
  opts.banner = 'Usage: server.rb [options]'

  opts.on('-s', '--secure', 'HTTPS mode') do |v|
    options[:secure] = v
  end

  opts.on('-p', '--port [Integer]', 'listen port') do |v|
    options[:port] = v
  end

  opts.on('-R', '--connection-rate [Integer]', 'limit receive rate of connection') do |v|
    options[:connection_rate] = v.to_i
  end

  opts.on('-r', '--stream-rate [Integer]', 'limit receive rate of stream') do |v|
    options[:stream_rate] = v.to_i
  end
end.parse!

puts "Starting server on port #{options[:port]}"
server = TCPServer.new(options[:port])

if options[:secure]
  ctx = OpenSSL::SSL::SSLContext.new
  ctx.cert = OpenSSL::X509::Certificate.new(File.open('keys/mycert.pem'))
  ctx.key = OpenSSL::PKey::RSA.new(File.open('keys/mykey.pem'))
  ctx.npn_protocols = [DRAFT]

  server = OpenSSL::SSL::SSLServer.new(server, ctx)
end

loop do
  sock = server.accept
  puts 'New TCP connection!'

  conn = HTTP2::Server.new(flow_controller: Throttle.new(rate: options[:connection_rate]),
                           stream_flow_controller_cb: proc {
                             Throttle.new(rate: options[:stream_rate])
                           }
                           )
  output_buffer = ""

  conn.on(:frame) do |bytes|
    # puts "Writing bytes: #{bytes.unpack("H*").first}"
    output_buffer << bytes
  end
  conn.on(:frame_sent) do |frame|
    puts "Sent frame: #{frame.inspect}"
  end
  conn.on(:frame_received) do |frame|
    puts "Received frame: #{frame.inspect}"
  end

  response_body = []

  conn.on(:stream) do |stream|
    log = Logger.new(stream.id)
    req, buffer = {}, ''

    stream.on(:active) { log.info 'cliend opened new stream' }
    stream.on(:close)  { log.info 'stream closed' }

    stream.on(:headers) do |h|
      req = Hash[*h.flatten]
      log.info "request headers: #{h}"
    end

    stream.on(:data) do |d|
      log.info "payload chunk: <<#{d}>>"
      buffer << d
    end

    stream.on(:half_close) do
      log.info 'client closed its end of the stream'

      response = nil
      if req[':method'] == 'POST'
        log.info "Received POST request, payload: #{buffer}"
        response = "Hello HTTP 2.0! POST payload: #{buffer}"
      else
        log.info 'Received GET request'
        response = 'Hello HTTP 2.0! GET request'
      end

      stream.headers({
        ':status' => '200',
        'content-length' => response.bytesize.to_s,
        'content-type' => 'text/plain',
      }, end_stream: false)

      response_body << { stream: stream, io: StringIO.new(response) }
    end
  end

  while !sock.closed?
    poll = []
    until response_body.empty?
      io = response_body.first[:io]
      s = response_body.first[:stream]
      n = [s.window, 1024].min

      data = io.read(n)
      eof = io.eof?

      if eof
        io.close
        response_body.shift
      end

      if n == 0 && !eof
        poll << :recv
        break
      else
        s.data(data || "", end_stream: eof)
      end
    end

    conn.flow_control_all

    until output_buffer.empty?
      begin
        n = sock.write_nonblock(output_buffer, exception: true)
        output_buffer.slice!(0, n)
      rescue IO::WaitWritable
        poll << :send
        break
      end
    end

    if poll.member?(:send)
      rs, = IO.select([sock], [sock], nil, 1)
    else
      rs, = IO.select([sock], nil, nil, 1)
    end

    if rs
      begin
        data = sock.read_nonblock(1024)
        # puts "Received bytes: #{data.unpack("H*").first}"
        conn << data
      rescue IO::WaitReadable
      rescue => e
        puts "Exception: #{e}, #{e.message} - closing socket."
        sock.close
      end
    end
  end
end
