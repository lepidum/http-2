data = [
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.8; rv:16.0) Gecko/20100101 Firefox/16.0",
  "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
  "http://www.craigslist.org/about/sites/",
  "cl_b=AB2BKbsl4hGM7M4nH5PYWghTM5A; cl_def_lang=en; cl_def_hp=shoals",
  "image/png,image/*;q=0.8,*/*;q=0.5",
  "BX=c99r6jp89a7no&b=3&s=q4; localization=en-us%3Bus%3Bus",
  ]

require './lib/http/2/huffman.rb'
require 'benchmark'

h = HTTP2::Header::Huffman.new

n = 100000
Benchmark.bm(7) do |x|
  x.report("naive:") { n.times{data.each{|d| h.encode(d)}} }
  x.report("table:") { n.times{data.each{|d| h.encode2(d)}} }
end
