module HTTP2
  class FramingException < Exception; end

  class Framer

    MAX_PAYLOAD_SIZE = 2**16-1
    MAX_STREAM_ID = 0x7fffffff
    MAX_WINDOWINC = 0x7fffffff
    RBIT          = 0x7fffffff
    RBYTE         = 0x0fffffff

    FRAME_TYPES = {
      data:          0x0,
      headers:       0x1,
      priority:      0x2,
      rst_stream:    0x3,
      settings:      0x4,
      push_promise:  0x5,
      ping:          0x6,
      goaway:        0x7,
      window_update: 0x9,
      continuation:  0xa
    }

    FRAME_FLAGS = {
      data: {
        end_stream:  0, reserved: 1
      },
      headers: {
        end_stream:  0, reserved: 1,
        end_headers: 2, priority: 3
      },
      priority:     {},
      rst_stream:   {},
      settings:     {},
      push_promise: { end_push_promise: 0 },
      ping:         { pong: 0 },
      goaway:       {},
      window_update:{},
      continuation: {
        end_stream: 0, end_headers: 1
      }
    }

    DEFINED_SETTINGS = {
      settings_max_concurrent_streams: 4,
      settings_initial_window_size:    7,
      settings_flow_control_options:   10
    }

    DEFINED_ERRORS = {
      no_error:           0,
      protocol_error:     1,
      internal_error:     2,
      flow_control_error: 3,
      stream_closed:      5,
      frame_too_large:    6,
      refused_stream:     7,
      cancel:             8,
      compression_error:  9
    }

    HEADERPACK = "SCCL"
    UINT32 = "L"

    # Frame header:
    # http://tools.ietf.org/html/draft-ietf-httpbis-http2-04#section-4.1
    #
    def commonHeader(frame)
      header = []

      if !FRAME_TYPES[frame[:type]]
        raise FramingException.new("Invalid frame type (#{frame[:type]})")
      end

      if frame[:length] > MAX_PAYLOAD_SIZE
        raise FramingException.new("Frame size is too large: #{frame[:length]}")
      end

      if frame[:stream] > MAX_STREAM_ID
        raise FramingException.new("Stream ID (#{frame[:stream]}) is too large")
      end

      if frame[:type] == :window_update && frame[:increment] > MAX_WINDOWINC
        raise FramingException.new("Window increment (#{frame[:increment]}) is too large")
      end

      header << frame[:length]
      header << FRAME_TYPES[frame[:type]]
      header << frame[:flags].reduce(0) do |acc, f|
        position = FRAME_FLAGS[frame[:type]][f]
        raise FramingException.new("Invalid frame flag (#{f}) for #{frame[:type]}") if !position
        acc |= (1 << position)
        acc
      end

      header << frame[:stream]
      header.pack(HEADERPACK) # 16,8,8,32
    end

    def readCommonHeader(buf)
      frame = {}
      frame[:length], type, flags, stream = buf.slice(0,8).unpack(HEADERPACK)

      frame[:type], _ = FRAME_TYPES.select { |t,pos| type == pos }.first
      frame[:flags] = FRAME_FLAGS[frame[:type]].reduce([]) do |acc, (name, pos)|
        acc << name if (flags & (1 << pos)) > 0
        acc
      end

      frame[:stream] = stream & RBIT
      frame
    end

    # http://tools.ietf.org/html/draft-ietf-httpbis-http2
    #
    def generate(frame)
      bytes  = ''
      length = 0

      frame[:flags]  ||= []
      frame[:stream] ||= 0

      case frame[:type]
      when :data
        bytes  += frame[:payload]
        length += frame[:payload].bytesize

      when :headers
        if frame[:priority]
          frame[:flags] += [:priority] if !frame[:flags].include? :priority
        end

        if frame[:flags].include? :priority
          bytes  += [frame[:priority] & RBIT].pack(UINT32)
          length += 4
        end

        bytes  += frame[:payload]
        length += frame[:payload].bytesize

      when :priority
        bytes  += [frame[:priority] & RBIT].pack(UINT32)
        length += 4

      when :rst_stream
        bytes  += pack_error frame[:error]
        length += 4

      when :settings
        if frame[:stream] != 0
          raise FramingException.new("Invalid stream ID (#{frame[:stream]})")
        end

        frame[:payload].each do |(k,v)|
          if !k.is_a? Integer
            k = DEFINED_SETTINGS[k]

            if k.nil?
              raise FramingException.new("Unknown settings ID for #{k}")
            end
          end

          bytes  += [k & RBYTE].pack(UINT32)
          bytes  += [v].pack(UINT32)
          length += 8
        end

      when :push_promise
        bytes  += [frame[:promise_stream] & RBIT].pack(UINT32)
        bytes  += frame[:payload]
        length += 4 + frame[:payload].bytesize

      when :ping
        if frame[:payload].bytesize != 8
          raise FramingException.new("Invalid payload size \
                                    (#{frame[:payload].size} != 8 bytes)")
        end
        bytes  += frame[:payload]
        length += 8

      when :goaway
        bytes  += [frame[:last_stream] & RBIT].pack(UINT32)
        bytes  += pack_error frame[:error]
        length += 8

        if frame[:payload]
          bytes  += frame[:payload]
          length += frame[:payload].bytesize
        end

      when :window_update
        bytes  += [frame[:increment] & RBIT].pack(UINT32)
        length += 4

      when :continuation
        bytes  += frame[:payload]
        length += frame[:payload].bytesize
      end

      frame[:length] = length
      commonHeader(frame) + bytes
    end

    def parse(buf)
      return nil if buf.size < 8
      frame = readCommonHeader(buf)
      return nil if buf.size < 8 + frame[:length]

      buf.read(8)
      payload = buf.read(frame[:length])

      case frame[:type]
      when :data
        frame[:payload] = payload.read(frame[:length])
      when :headers
        if frame[:flags].include? :priority
          frame[:priority] = payload.read(4).unpack(UINT32).first & RBIT
        end
        frame[:payload] = payload.read(frame[:length])
      when :priority
        frame[:priority] = payload.read(4).unpack(UINT32).first & RBIT
      when :rst_stream
        frame[:error] = unpack_error payload.read(4).unpack(UINT32).first

      when :settings
        frame[:payload] = {}
        (frame[:length] / 8).times do
          id  = payload.read(4).unpack(UINT32).first & RBYTE
          val = payload.read(4).unpack(UINT32).first

          name, _ = DEFINED_SETTINGS.select { |name, v| v == id }.first
          frame[:payload][name || id] = val
        end
      when :push_promise
        frame[:promise_stream] = payload.read(4).unpack(UINT32).first & RBIT
        frame[:payload] = payload.read(frame[:length])
      when :ping
        frame[:payload] = payload.read(frame[:length])
      when :goaway
        frame[:last_stream] = payload.read(4).unpack(UINT32).first & RBIT
        frame[:error] = unpack_error payload.read(4).unpack(UINT32).first

        size = frame[:length] - 8
        frame[:payload] = payload.read(size) if size > 0
      when :window_update
        frame[:increment] = payload.read(4).unpack(UINT32).first & RBIT
      when :continuation
        frame[:payload] = payload.read(frame[:length])
      end

      frame
    end

    private

    def pack_error(e)
      if !e.is_a? Integer
        e = DEFINED_ERRORS[e]

        if e.nil?
          raise FramingException.new("Unknown error ID for #{e}")
        end
      end

      [e].pack(UINT32)
    end

    def unpack_error(e)
      name, _ = DEFINED_ERRORS.select { |name, v| v == e }.first
      name || error
    end

  end
end
