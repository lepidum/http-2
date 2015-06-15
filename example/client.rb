require_relative 'helper'
require 'stringio'

options = {}
OptionParser.new do |opts|
  opts.banner = 'Usage: client.rb [options]'

  opts.on('-d', '--data [String]', 'HTTP payload') do |v|
    options[:payload] = case v
                        when /^@/
                          open($', 'r')
                        else
                          StringIO.new(v)
                        end
  end

  opts.on('-R', '--connection-rate [Integer]', 'limit receive rate of connection') do |v|
    options[:connection_rate] = v.to_i
  end

  opts.on('-r', '--stream-rate [Integer]', 'limit receive rate of stream') do |v|
    options[:stream_rate] = v.to_i
  end
end.parse!

uri = URI.parse(ARGV[0] || 'http://localhost:8080/')
tcp = TCPSocket.new(uri.host, uri.port)
sock = nil

if uri.scheme == 'https'
  ctx = OpenSSL::SSL::SSLContext.new
  ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE

  ctx.npn_protocols = [DRAFT]
  ctx.npn_select_cb = lambda do |protocols|
    puts "NPN protocols supported by server: #{protocols}"
    DRAFT if protocols.include? DRAFT
  end

  sock = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
  sock.sync_close = true
  sock.hostname = uri.hostname
  sock.connect

  if sock.npn_protocol != DRAFT
    puts "Failed to negotiate #{DRAFT} via NPN"
    exit
  end
else
  sock = tcp
end

conn = HTTP2::Client.new(flow_controller: Throttle.new(rate: options[:connection_rate]))
output_buffer = ""

conn.on(:frame) do |bytes|
  puts "Sending bytes: #{bytes.unpack("H*").first[0, 32]}..."
  output_buffer << bytes
end
conn.on(:frame_sent) do |frame|
  puts "Sent frame: #{frame.inspect}"
end
conn.on(:frame_received) do |frame|
  puts "Received frame: #{frame.inspect}"
end

stream = conn.new_stream(flow_controller: Throttle.new(rate: options[:stream_rate]))
log = Logger.new(stream.id)

conn.on(:promise) do |promise|
  promise.on(:headers) do |h|
    log.info "promise headers: #{h}"
  end

  promise.on(:data) do |d|
    log.info "promise data chunk: <<#{d.size}>>"
  end
end

conn.on(:altsvc) do |f|
  log.info "received ALTSVC #{f}"
end

stream.on(:close) do
  log.info 'stream closed'
  sock.close
end

stream.on(:half_close) do
  log.info 'closing client-end of the stream'
end

stream.on(:headers) do |h|
  log.info "response headers: #{h}"
end

stream.on(:data) do |d|
  #log.info "response data chunk: <<#{d}>>"
end

stream.on(:altsvc) do |f|
  log.info "received ALTSVC #{f}"
end

head = {
  ':scheme' => uri.scheme,
  ':method' => (options[:payload].nil? ? 'GET' : 'POST'),
  ':authority' => [uri.host, uri.port].join(':'),
  ':path' => uri.path.empty? ? '/' : uri.path,
  'accept' => '*/*',
}

request_body = []

puts 'Sending HTTP 2.0 request'
if head[':method'] == 'GET'
  stream.headers(head, end_stream: true)
else
  stream.headers(head, end_stream: false)
  request_body << { stream: stream, io: options[:payload] }
end

while !sock.closed?
  poll = []
  until request_body.empty?
    io = request_body.first[:io]
    s = request_body.first[:stream]
    n = [s.window, 1024].min

    data = io.read(n)
    eof = io.eof?

    if eof
      io.close
      request_body.shift
    end

    if n == 0 && !eof
      poll << :recv
      break
    else
      stream.data(data || "", end_stream: eof)
    end
  end

  conn.flow_control
  stream.flow_control

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
    data = sock.read_nonblock(1024)
    # puts "Received bytes: #{data.unpack("H*").first}"

    begin
      conn << data
    rescue => e
      puts "Exception: #{e}, #{e.message} - closing socket."
      sock.close
    end
  end
end
