module Autobots
  class Runner

    @after_hooks = []

    def self.after_run(&blk)
      @after_hooks << blk
    end

    def self.run!(args)
      exit_code = self.run(args)
      @after_hooks.reverse_each(&:call)
      Kernel.exit(exit_code || false)
    end

    def self.run args = []
      Minitest.load_plugins

      options = Minitest.process_args args

      reporter = Minitest::CompositeReporter.new
      reporter << Minitest::SummaryReporter.new(options[:io], options)
      reporter << Minitest::ProgressReporter.new(options[:io], options)

      Minitest.reporter = reporter # this makes it available to plugins
      Minitest.init_plugins options
      Minitest.reporter = nil # runnables shouldn't depend on the reporter, ever

      reporter.start
      Minitest.__run reporter, options
      Minitest.parallel_executor.shutdown
      reporter.report

      reporter.passed?
    end

  end
end
