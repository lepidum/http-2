require_relative 'helper'

$options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: client2.rb [OPTIONS] [-- --data 'String'] url1 [--data 'String'] url2 url3 ..."

  opts.on("-p", "--protocol [#{DRAFT}]", "NPN/ALPN protocol") do |v|
    $options[:protocol] = v
  end
end.parse!

# Connect to host and return [Connection, Socket]
class Peer
  attr_reader :host, :port, :scheme
  attr_reader :logger
  attr_reader :sock
  attr_reader :streams

  def initialize(uri)
    @logger = Logger.new(0)
    uri = URI.parse(uri)
    @host, @port, @scheme = uri.host, uri.port, uri.scheme
    tcp = TCPSocket.new(@host, @port)
    sock = nil

    if @scheme == 'https'
      OpenSSL.debug = true
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE

      proto = $options[:protocol] || DRAFT
      ctx.npn_protocols = [proto]
      ctx.npn_select_cb = lambda do |protocols|
        @logger.info "NPN protocols supported by server: #{protocols}"
        proto if protocols.include? proto
      end

      @sock = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
      @sock.sync_close = true
      @sock.hostname = uri.hostname
      @sock.connect

      if @sock.npn_protocol != proto
        @logger.info "Failed to negotiate #{proto} via NPN"
        exit
      end
    else
      @sock = tcp
    end

    @conn = HTTP2::Client.new
    @conn.on(:frame) do |bytes|
      # @logger.info "Sending bytes: #{bytes.unpack("H*").first}"
      @sock.print bytes
      @sock.flush
    end
    @conn.on(:frame_sent) do |frame|
      @logger.info "Sent frame: #{frame.inspect}"
    end
    @conn.on(:frame_received) do |frame|
      @logger.info "Received frame: #{frame.inspect}"
    end
    @conn.on(:goaway) do |last_stream, error, payload|
      @logger.info "Connection closed by GOAWAY"
      @sock.close
    end

    @streams = []
  end

  def mainloop
    while !@sock.closed? && !(@sock.eof? rescue true)
      data = @sock.read_nonblock(1024)
      # puts "Received bytes: #{data.unpack("H*").first}"

      begin
        @conn << data
      rescue Exception => e
        @logger.info "Exception: #{e}, #{e.message} - closing socket and exit."
        @sock.close
      end
    end
  end

  # Create a new stream and return
  def new_stream(uri)
    uri = URI.parse(uri) if uri.is_a?(String)

    stream = @conn.new_stream
    @streams << stream
    log = Logger.new(stream.id)

    @conn.on(:promise) do |promise|
      promise.on(:headers) do |h|
        log.info "promise headers: #{h}"
      end

      promise.on(:data) do |d|
        log.info "promise data chunk: <<#{d.size}>>"
      end
    end

    @conn.on(:altsvc) do |f|
      log.info "received ALTSVC #{f}"
    end

    stream.on(:close) do
      log.info "stream closed"
      @streams.delete(stream)
      if @streams.size == 0
        @logger.info "All streams closed. Finished"
        @conn.goaway
        @sock.close
      end
    end

    stream.on(:half_close) do
      log.info "closing client-end of the stream"
    end

    stream.on(:headers) do |h|
      log.info "response headers: #{h}"
    end

    stream.on(:data) do |d|
      log.info "response data chunk: <<#{d}>>"
      stream.send({type: :window_update, increment: d.size})
    end

    stream.on(:altsvc) do |f|
      log.info "received ALTSVC #{f}"
    end

    stream
  end

  def request(uri, payload = nil)
    uri = URI.parse(uri) if uri.is_a?(String)
    unless uri.host == @host && uri.port == @port && uri.scheme == @scheme
      abort "Domain mismatch #{[@host,@port,@scheme]} vs #{[uri.host,uri.port,uri.scheme]}"
    end

    head = {
      ":scheme" => uri.scheme,
      ":method" => (payload.nil? ? "GET" : "POST"),
      ":authority" => [uri.host, uri.port].join(':'),
      ":path" => uri.path,
      "accept" => "*/*"
    }

    stream = new_stream(uri)
    log = Logger.new(stream.id)

    log.info "Sending HTTP 2.0 request"
    if head[":method"] == "GET"
      stream.headers(head, end_stream: true)
    else
      stream.headers(head, end_stream: false)
      stream.data(payload)
    end

    stream
  end
end

peer = nil
data = nil
while ARGV.size > 0

  uri = ARGV.shift
  while uri == '--data'
    data ||= ''
    data << ARGV.shift
    uri = ARGV.shift
  end

  peer ||= Peer.new(uri)
  peer.request(uri, data)
  data = nil
end

peer.mainloop
