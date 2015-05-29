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

class Throttle
  def initialize(rate)
    @rate = rate
    @start_time = Time.now
    @bytes = 0
    @consumed = 0
  end

  def add(n)
    @bytes += n
  end

  def window_update
    current_time = Time.now
    if @rate
      allowed = (@rate * (current_time - @start_time)).to_i
    else
      allowed = @bytes
    end
    consumed = [allowed, @bytes].min
    diff = consumed - @consumed
    #diff = [1024, diff].min
    @consumed += diff
    diff
  end
end
