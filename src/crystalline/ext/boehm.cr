lib LibGC
  fun set_free_space_divisor = GC_set_free_space_divisor(size : LibGC::Word) : Void
  fun enable_incremental = GC_enable_incremental : Void
  fun set_force_unmap_on_gcollect = GC_set_force_unmap_on_gcollect(size : LibC::Int) : Void
end

module GC
  # How much free space Boehm keeps after a collection, as `heap_size /
  # divisor`. A smaller divisor collects less often and runs faster, at the
  # cost of a larger heap.
  #
  # Boehm's default of 3 is tuned for ordinary programs. Crystalline runs a
  # compiler in-process, which is a very different shape: one analysis
  # allocates hundreds of megabytes of AST and type graph, nearly all of it
  # live until the analysis ends, and collection accounts for a quarter of the
  # time it takes.
  #
  # Startup analysis of ameba-ls, release build, over the wire, four runs each:
  #
  #     divisor 3 (default)   2.60 2.65 2.64 2.61 s
  #     divisor 1             2.11 2.10 2.10 2.09 s
  #
  # The heap it settles at is around 10% larger for that. Raise this through
  # the environment on a machine that would rather have the memory back. A
  # middle ground of 2 did not measure consistently better than either end, so
  # there is no considered recommendation between them.
  DEFAULT_FREE_SPACE_DIVISOR = 1_u64

  # Tune the collector for the allocation pattern of repeated analyses.
  #
  # Deliberately not done in `GC.init`: nothing before this point allocates
  # enough for the setting to matter, and leaving startup alone keeps this out
  # of the way of anything that embeds the workspace without the server.
  def self.configure_for_analysis : Nil
    LibGC.set_free_space_divisor(LibGC::Word.new(free_space_divisor))
  end

  private def self.free_space_divisor : UInt64
    configured = ENV["CRYSTALLINE_GC_FREE_SPACE_DIVISOR"]?.try(&.to_u64?)
    # A divisor of zero asks for an unbounded heap.
    return configured if configured && configured > 0
    DEFAULT_FREE_SPACE_DIVISOR
  end
end

# Boehm's incremental mode is left alone on purpose. It tracks dirty pages with
# `mprotect`, and against a multi-gigabyte pointer-dense heap that made an
# analysis more than two hundred times slower on macOS - 4 analyses of crecto
# did not finish in four minutes, against 1.2 seconds without it.
