# encoding: utf-8
require 'ipaddr'
require 'wavefile'
require 'ffi'
require 'sippy_cup/media/pcmu_payload'
require 'sippy_cup/media/dtmf_payload'
require 'sippy_cup/g711'

module SippyCup
  class Media
    VALID_STEPS = %w{silence dtmf play}.freeze
    USEC = 1_000_000
    MSEC = 1_000
    attr_accessor :sequence

    def initialize(from_addr, from_port, to_addr, to_port, generator = PCMUPayload)
      @from_addr, @to_addr = IPAddr.new(from_addr), IPAddr.new(to_addr)
      @from_port, @to_port, @generator = from_port, to_port, generator
      reset!
    end

    def reset!
      @sequence = []
    end

    def <<(input)
      get_step input # validation
      @sequence << input
    end

    def empty?
      @sequence.empty?
    end

    def compile!
      sequence_number = 0
      start_time = Time.now
      @pcap_file = PacketFu::PcapFile.new
      timestamp = 0
      elapsed = 0
      ssrc_id = rand 2147483648
      first_audio = true

      @sequence.each do |input|
        action, value = get_step input

        case action
        when 'silence'
          # value is the duration in milliseconds
          # append that many milliseconds of silent RTP audio
          (value.to_i / @generator::PTIME).times do
            packet = new_packet
            rtp_frame = @generator.new
            # The first RTP audio packet should have the marker bit set
            if first_audio
              rtp_frame.rtp_marker = 1
              first_audio = false
            end
            rtp_frame.rtp_timestamp = timestamp += rtp_frame.timestamp_interval
            elapsed += rtp_frame.ptime
            rtp_frame.rtp_sequence_num = sequence_number += 1
            rtp_frame.rtp_ssrc_id = ssrc_id
            packet.headers.last.body = rtp_frame.to_bytes
            packet.recalc
            @pcap_file.body << get_pcap_packet(packet, next_ts(start_time, elapsed))
          end
        when 'dtmf'
          # value is the DTMF digit to send
          # append that RFC4733 digit
          # Assume 0.2 second duration for now
          count = 200 / DTMFPayload::PTIME
          count.times do |i|
            packet = new_packet
            dtmf_frame = DTMFPayload.new value
            # The first RTP audio packet should have the marker bit set
            if first_audio
              rtp_frame.rtp_marker = 1
              first_audio = false
            end
            dtmf_frame.rtp_timestamp = timestamp += dtmf_frame.timestamp_interval
            elapsed += dtmf_frame.ptime
            dtmf_frame.rtp_sequence_num = sequence_number += 1
            dtmf_frame.rtp_ssrc_id = ssrc_id
            dtmf_frame.end_of_event = (i == count-1) # Last packet
            packet.headers.last.body = dtmf_frame.to_bytes
            packet.recalc
            @pcap_file.body << get_pcap_packet(packet, next_ts(start_time, elapsed))
          end
          # Now bump up the timestamp to cover the gap
          timestamp += count * DTMFPayload::TIMESTAMP_INTERVAL
        when 'play'
          # value is wav file path
          wav = WaveFile::Reader.new(value, WaveFile::Format.new(:mono, :pcm_16, 8000))
          duration = wav.total_sample_frames * 1000 / wav.native_format.sample_rate # in milliseconds
          (duration / @generator::PTIME).times do |i|
            packet = new_packet
            rtp_frame = @generator.new
            # The first RTP audio packet should have the marker bit set
            if first_audio
              rtp_frame.rtp_marker = 1
              first_audio = false
            end
            rtp_frame.rtp_timestamp = timestamp += rtp_frame.timestamp_interval
            elapsed += rtp_frame.ptime
            rtp_frame.rtp_sequence_num = sequence_number += 1
            rtp_frame.rtp_ssrc_id = ssrc_id
            len = wav.native_format.sample_rate * rtp_frame.ptime / 1000
            lin_data = wav.read(len).samples
			enc_data = G711::encode(lin_data)
            packet.headers.last.body = rtp_frame.header.to_s << enc_data.flatten.pack('c*')
            packet.recalc
            @pcap_file.body << get_pcap_packet(packet, next_ts(start_time, elapsed))
          end
          wav.close
        else
        end
      end
      @pcap_file
    end

  private

    def get_step(input)
      action, value = input.split ':'
      raise "Invalid Sequence: #{input}" unless VALID_STEPS.include? action

      [action, value]
    end


    def get_pcap_packet(packet, timestamp)
      PacketFu::PcapPacket.new :timestamp => timestamp,
                               :incl_len => packet.to_s.size,
                               :orig_len => packet.to_s.size,
                               :data => packet.to_s
    end

    def next_ts(start_time, offset)
      distance = offset * MSEC
      sec = start_time.to_i + (distance / USEC)
      usec = distance % USEC
      PacketFu::Timestamp.new(sec: sec, usec: usec).to_s
    end

    def new_packet
      packet = PacketFu::UDPPacket.new
      packet.ip_src = @from_addr.to_i
      packet.ip_dst = @to_addr.to_i
      packet.udp_src = @from_port
      packet.udp_dst = @to_port
      packet
    end
  end
end
