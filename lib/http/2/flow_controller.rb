module HTTP2

  class FlowController
    include Emitter

    attr_reader :current_window

    MAX_WINDOW = 0x7fffffff

    attr_reader :max_window
    attr_reader :threshold

    def initialize(initial_window: 65_535, threshold: 2_048, max_window: nil)
      @max_window = [max_window || initial_window, MAX_WINDOW].min
      @current_window = initial_window
      @threshold = threshold
    end

    def window_update
      return nil if current_window >= threshold
      return nil if max_window <= current_window
      max_window - current_window
    end

    def limit_window_update(incr)
      return nil if incr <= 0
      [incr, Framer::MAX_WINDOWINC].min
    end

    def receive(n)
      emit(:receive, n)
      @current_window -= n
    end

    def apply_window_update(incr)
      emit(:update, incr)
      @current_window += incr
    end

    def create_window_update
      incr = window_update
      return nil unless incr
      incr = limit_window_update(incr)
      return nil unless incr
      apply_window_update(incr)
      incr
    end


  end
end
