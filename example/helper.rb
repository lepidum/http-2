$LOAD_PATH << 'lib' << '../lib'

require 'optparse'
require 'socket'
require 'openssl'
require 'http/2'
require 'uri'

DRAFT = 'h2-16'

class Logger
  def initialize(id)
    @id = id
  end

  def info(msg)
    puts "[Stream #{@id}]: #{msg}"
  end
end

class Throttle < HTTP2::FlowController
  def initialize(rate: nil, **args)
    super(args)
    @rate = rate
    @received_bytes = 0
    on(:receive) {|n|
      @received_bytes += n
      @start_time ||= Time.now
    }
  end

  def threshold
    thresholds = [super]
    if @rate && @start_time
      current_time = Time.now
      limit = (@rate * (current_time - @start_time)).to_i
      space = [limit - @received_bytes, 0].max
      thresholds << space
    end
    thresholds.min
  end
end
