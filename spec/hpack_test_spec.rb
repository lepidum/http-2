require "helper"
require 'json'

describe HTTP2::Header do
  context "Decompressor" do
    ['nghttp2'].each do |folder|
      path = File.expand_path("hpack-test-case/#{folder}", File.dirname(__FILE__))
      Dir.foreach(path) do |file|
        next if file !~ /\.json/
        it "should decode #{file}" do
          story = JSON.parse(File.read("#{path}/#{file}"))
          cases = story['cases']
          table_size = cases[0]['header_table_size'] || 4096
          @dc = Decompressor.new(:request, table_size: table_size)
          cases.each do |c|
            wire = [c['wire']].pack("H*").force_encoding('binary')
            @emitted = @dc.decode(HTTP2::Buffer.new(wire))
            expected = c['headers'].flat_map(&:to_a)
            Set[*@emitted].should eq Set[*expected]
          end
        end
      end
    end
  end
end

