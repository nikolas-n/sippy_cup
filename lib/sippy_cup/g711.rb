# ffi interface to freeswitch's g711
require 'ffi'

module SippyCup
  module G711
    extend FFI::Library
    ffi_lib 'spandsp'

    enum :EncodeState, [
      :G711_ALAW, 0,
      :G711_ULAW, 1,
    ]

    class G711State < FFI::Struct
      layout :mode,  :EncodeState
    end

    attach_function :g711_encode, [ G711State, :pointer, :pointer, :int ], :int

    def encode(samples)
      state = G711State.new
      state[:mode] = :G711_ULAW # u-law only

      iptr = FFI::MemoryPointer.new(:int16, samples.size)
      optr = FFI::MemoryPointer.new(:uint8, samples.size)

	  #puts samples.join(' ')
      iptr.write_array_of_type(:int16, :write_int16, samples)
      g711_encode(state, optr, iptr, samples.size)
      output = optr.read_array_of_type(:uint8, :read_uint8, samples.size)
	  #puts output.join(' ')
      output
    end
    module_function :encode
  end
end
