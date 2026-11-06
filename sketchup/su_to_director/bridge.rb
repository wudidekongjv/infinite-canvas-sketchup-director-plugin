# encoding: UTF-8
require 'socket'
require 'uri'

module SuToDirector
  # 极简 HTTP/1.1 服务（不依赖 webrick，SketchUp 自带 Ruby 里没有该 gem）
  # 只监听 127.0.0.1，供本机导演台页面读取机位/遮挡体、回传渲染帧。
  class HttpBridge
    attr_reader :port

    def initialize(port, &handler)
      @port = port.to_i
      @handler = handler
      @server = nil
      @thread = nil
      @running = false
    end

    def running?
      @running
    end

    def start
      return false if @running
      @server = TCPServer.new('127.0.0.1', @port)
      @running = true
      # 重要：SketchUp 2026（Ruby 3.2）里 Thread 起的 accept 不会真正推进
      # （实测线程停在 sleep、端口在监听但永不响应），所以改用 UI.start_timer
      # 在主线程里轮询 accept_nonblock。handle_request 里可以安全碰 SketchUp API。
      @timer = ::UI.start_timer(0.05, true) { poll }
      true
    rescue StandardError => e
      @running = false
      @timer = nil
      raise e
    end

    def stop
      @running = false
      if @timer
        begin
          ::UI.stop_timer(@timer)
        rescue StandardError
          nil
        end
        @timer = nil
      end
      begin
        @server.close if @server
      rescue StandardError
        nil
      end
      @server = nil
      @thread = nil
      true
    end

    private

    def poll
      return unless @running && @server
      budget = 4
      while budget > 0
        client = @server.accept_nonblock(exception: false)
        break unless client.is_a?(TCPSocket)
        serve(client)
        budget -= 1
      end
    rescue StandardError
      nil
    end

    def serve(client)
      method = 'GET'
      path = '/'
      query = {}
      headers = {}
      body = ''

      # 主线程处理，等不到数据就放弃这个连接，避免把 SketchUp 界面卡住
      ready = ::IO.select([client], nil, nil, 1.0)
      return client.close if ready.nil?

      request_line = client.gets("\r\n")
      return client.close if request_line.nil?

      parts = request_line.strip.split(' ')
      method = parts[0].to_s.upcase
      target = parts[1].to_s

      if target.include?('?')
        raw_path, raw_query = target.split('?', 2)
        path = raw_path
        begin
          URI.decode_www_form(raw_query.to_s, Encoding::UTF_8).each { |k, v| query[k] = v }
        rescue StandardError
          query = {}
        end
      else
        path = target
      end

      while (line = client.gets("\r\n"))
        break if line.strip.empty?
        key, value = line.split(':', 2)
        headers[key.to_s.strip.downcase] = value.to_s.strip if key
      end

      length = headers['content-length'].to_i
      if length > 0
        body = client.read(length) || ''
      end

      if method == 'OPTIONS'
        write_response(client, 204, 'text/plain', '')
        return client.close
      end

      status = 200
      content_type = 'application/json; charset=utf-8'
      payload = ''
      begin
        result = @handler.call(method, path, query, headers, body)
        if result.is_a?(Array)
          status = result[0]
          content_type = result[1]
          payload = result[2]
        else
          payload = result.to_s
        end
      rescue StandardError => e
        status = 500
        content_type = 'application/json; charset=utf-8'
        payload = %({"ok":false,"error":"#{escape(e.message)}"})
      end

      write_response(client, status, content_type, payload)
    rescue StandardError
      nil
    ensure
      begin
        client.close unless client.closed?
      rescue StandardError
        nil
      end
    end

    def escape(text)
      text.to_s.gsub('\\', '\\\\').gsub('"', '\\"').gsub("\n", ' ').gsub("\r", ' ')
    end

    def write_response(client, status, content_type, payload)
      payload = payload.to_s
      body = payload.dup.force_encoding('BINARY')
      head = []
      head << "HTTP/1.1 #{status} #{status_text(status)}"
      head << 'Access-Control-Allow-Origin: *'
      head << 'Access-Control-Allow-Methods: GET, POST, OPTIONS'
      head << 'Access-Control-Allow-Headers: Content-Type, Content-Length, X-Requested-With'
      head << 'Access-Control-Max-Age: 600'
      head << 'Cache-Control: no-store, max-age=0'
      head << "Content-Type: #{content_type}"
      head << "Content-Length: #{body.bytesize}"
      head << 'Connection: close'
      head << ''
      client.write(head.join("\r\n") + "\r\n")
      client.write(body) unless body.empty?
    end

    def status_text(code)
      case code
      when 200 then 'OK'
      when 204 then 'No Content'
      when 404 then 'Not Found'
      when 405 then 'Method Not Allowed'
      when 500 then 'Internal Server Error'
      else 'OK'
      end
    end
  end
end
