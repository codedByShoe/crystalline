# Serializes compilations, and lets a request decline to queue behind one.
#
# The compiler holds process-wide state and is not reentrant, so only one
# analysis may run at a time. What a plain `Mutex` cannot express is the reason
# this exists: the first analysis of a project takes as long as it takes - tens
# of seconds on a large one - and a completion that waits it out answers a
# keystroke that stopped being interesting several keystrokes ago. An
# interactive request would rather answer from what it already knows than be
# right long after the fact, so it needs to ask whether the compiler is free
# instead of blocking until it is.
class Crystalline::CompilationLock
  # A single token. Holding it is holding the right to run a compilation.
  @slot = Channel(Nil).new(1)
  # Mirrors whether the token is held. The token itself cannot be examined
  # without taking it, and taking it is the thing `#available?` exists to avoid.
  @compiling = Atomic(Int32).new(0)
  # Best effort, and only ever compared against the running fiber: whoever set
  # it is the only fiber it can be equal to.
  @holder : Fiber? = nil

  def initialize
    @slot.send(nil)
  end

  # Runs the block once the compiler is free, waiting for as long as that takes.
  def synchronize(&)
    check_reentrance
    @slot.receive
    @compiling.set(1)
    @holder = Fiber.current
    begin
      yield
    ensure
      @holder = nil
      @compiling.set(0)
      @slot.send(nil)
    end
  end

  # Whether a compilation could be started right now.
  #
  # This is a fact about the moment it is asked, not a reservation: a
  # compilation may start between the answer and the call that acts on it, and
  # that caller then waits - which is what it would have done anyway. The
  # condition worth avoiding lasts for seconds, so it is seen reliably.
  def available? : Bool
    @compiling.get.zero?
  end

  # Waits up to *span* for the compiler to become free, and reports whether it
  # is. A caller that cannot spend an unbounded amount of time waiting can still
  # afford to wait out a compilation that is nearly over, and most are.
  def wait_until_available(span : Time::Span) : Bool
    select
    when @slot.receive
      # Taken only to learn that it was there. Nothing else can hold it in the
      # meantime, so handing it straight back cannot block.
      @slot.send(nil)
      true
    when timeout(span)
      false
    end
  end

  # A channel deadlocks where a checked `Mutex` raises, so the mistake that
  # would produce one is reported rather than hung on.
  private def check_reentrance
    return unless @holder == Fiber.current
    raise "Attempted to run a compilation from within a compilation"
  end
end
