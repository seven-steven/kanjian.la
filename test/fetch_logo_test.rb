# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "socket"
require_relative "../scripts/fetch_logo"

class FetchLogoTest < Minitest::Test
  def test_fetches_image_response
    with_server do |server|
      Dir.mktmpdir do |directory|
        output = File.join(directory, "logo.png")
        FetchLogo.fetch("http://127.0.0.1:#{server}/image", output)

        assert_equal "image", File.binread(output)
      end
    end
  end

  def test_rejects_non_image_response
    with_server do |server|
      Dir.mktmpdir do |directory|
        error = assert_raises(ArgumentError) do
          FetchLogo.fetch("http://127.0.0.1:#{server}/text", File.join(directory, "logo"))
        end

        assert_equal "response is not an image", error.message
      end
    end
  end

  private

  def with_server
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      2.times do
        client = server.accept
        request = client.gets
        path = request.split[1]
        body, content_type = path == "/image" ? ["image", "image/png"] : ["text", "text/plain"]
        client.write("HTTP/1.1 200 OK\r\nContent-Type: #{content_type}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      end
    end
    yield port
  ensure
    server&.close
    thread&.join
  end
end
