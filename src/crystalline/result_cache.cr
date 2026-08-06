class Crystalline::ResultCache
  # A cache of compiler results with invalidation time, indexed by file name.
  @cache : Hash(String, {Crystal::Compiler::Result?, Time::Instant?}) = Hash(String, {Crystal::Compiler::Result?, Time::Instant?}).new
  # Requests are handled in independent fibers - which run in parallel when the
  # server is built with `-Dpreview_mt` - so the underlying hash needs to be
  # guarded. Reentrant because `set` performs an invalidation check.
  @mutex = Mutex.new(:reentrant)

  # Remove the result, store the timestamp.
  def invalidate(entry : String)
    @mutex.synchronize { @cache[entry] = {nil, monotonic_now} }
  end

  # True if the entry (filename) has already been used as a compilation target.
  def exists?(entry : String)
    @mutex.synchronize { @cache.has_key?(entry) }
  end

  # True if the cache has been invalidated *since* the *since* time argument,
  # or if the entry is invalided if *since* is not provided.
  def invalidated?(entry : String, *, since : Time::Instant? = nil) : Bool
    @mutex.synchronize do
      entry_value = @cache[entry]?
      return false unless entry_value
      invalidation_time = entry_value[1]
      if since
        !invalidation_time || invalidation_time > since
      else
        !invalidation_time.nil?
      end
    end
  end

  # Get a cache value.
  def get(entry : String)
    @mutex.synchronize { @cache[entry]?.try &.[0] }
  end

  # Store a compiler result by target name.
  #
  # If *unless_invalidated_since* is provided, is will not store the result if the previous result has been
  # invalidated since the privided timestamp.
  def set(entry : String, result : Crystal::Compiler::Result?, *, unless_invalidated_since : Time::Instant? = nil)
    @mutex.synchronize do
      invalidated = unless_invalidated_since && invalidated?(entry, since: unless_invalidated_since)
      @cache[entry] = {result, nil} unless invalidated
    end
  end

  # Forget everything known about *entry*, releasing the cached compiler result.
  def forget(entry : String)
    @mutex.synchronize { @cache.delete(entry) }
  end

  # Return the current monotonic time.
  def monotonic_now
    Time.instant
  end
end
