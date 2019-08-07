require "./raven"

module Raven
  class CrashHandler
    # Example:
    #
    # ```
    # Invalid memory access (signal 11) at address 0x20
    # [0x1057a9fab] *CallStack::print_backtrace:Int32 +107
    # [0x105798aac] __crystal_sigfault_handler +60
    # [0x7fff9ca0652a] _sigtramp +26
    # [0x105cb35a1] GC_realloc +50
    # [0x1057870bb] __crystal_realloc +11
    # [0x1057d3ecc] *Pointer(UInt8)@Pointer(T)#realloc<Int32>:Pointer(UInt8) +28
    # [0x10578706c] __crystal_main +2940
    # [0x105798128] main +40
    # ```
    CRYSTAL_CRASH_PATTERN = /(?<message>[^\n]+)\n(?<backtrace>\[#{Backtrace::Line::ADDR_FORMAT}\] .*)$/m

    # Example:
    #
    # ```
    # Unhandled exception: Index out of bounds (IndexError)
    #   from /usr/local/Cellar/crystal/0.26.0/src/indexable.cr:596:8 in 'at'
    #   from /eval:1:1 in '__crystal_main'
    #   from /usr/local/Cellar/crystal/0.26.0/src/crystal/main.cr:104:5 in 'main_user_code'
    #   from /usr/local/Cellar/crystal/0.26.0/src/crystal/main.cr:93:7 in 'main'
    #   from /usr/local/Cellar/crystal/0.26.0/src/crystal/main.cr:133:3 in 'main'
    # ```
    CRYSTAL_EXCEPTION_PATTERN = /Unhandled exception(?<in_fiber> in spawn(?:\(name: (?<fiber_name>.*?)\))?)?: (?<message>[^\n]+) \((?<class>[A-Z]\w+)\)\n(?<backtrace>(?:\s+from\s+.*?){1,})$/m

    # Default event options.
    DEFAULT_OPTS = {
      logger:      "raven.crash_handler",
      fingerprint: ["{{ default }}", "process.crash"],
    }

    # Process executable path.
    property name : String
    # An `Array` of arguments passed to process.
    property args : Array(String)?

    # FIXME: doesn't work yet due to usage of global Raven within `Backtrace::Line`.
    #
    # ```
    # getter raven : Instance { Instance.new }
    # ```
    getter raven : Instance { Raven.instance }

    delegate :context, :configuration, :configure, :capture,
      to: raven

    property logger : ::Logger {
      Logger.new({{ "STDOUT".id unless flag?(:release) }}).tap do |logger|
        logger.level = {{ flag?(:debug) ? "Logger::DEBUG".id : "Logger::ERROR".id }}

        "#{logger.progname}.crash_handler".tap do |progname|
          logger.progname = progname
          configuration.exclude_loggers << progname
        end
      end
    }

    def initialize(@name, @args)
      context.extra.merge!({
        process: {name: @name, args: @args},
      })
    end

    private def configure!
      configure do |config|
        config.logger = logger
        config.send_modules = false
        config.processors = [
          Processor::UTF8Conversion,
          Processor::SanitizeData,
          Processor::Compact,
        ] of Processor.class
      end
    end

    private def capture_with_options(*args, **options)
      capture(*args) do |event|
        event.initialize_with **DEFAULT_OPTS
        event.initialize_with **options
        yield event
      end
    end

    private def capture_with_options(*args, **options)
      capture_with_options(*args, **options) { }
    end

    private def capture_with_options(**options)
      yield
    rescue ex : Raven::Error
      raise ex # Don't capture Raven errors
    rescue ex : Exception
      capture_with_options(ex, **options) { }
      raise ex
    end

    private def capture_crystal_exception(klass, msg, backtrace, **options)
      capture_with_options klass, msg, backtrace, **options
    end

    private def capture_crystal_crash(msg, backtrace)
      capture_with_options msg do |event|
        event.level = :fatal
        event.backtrace = backtrace
        # we need to overwrite the fingerprint due to varied
        # pointer addresses in crash messages, otherwise resulting
        # in new event per crash
        event.fingerprint.tap do |fingerprint|
          fingerprint.delete "{{ default }}"
          fingerprint << "process: #{name}"
          if culprit = event.culprit
            fingerprint << "culprit: #{culprit}"
          end
        end
      end
    end

    private def capture_process_failure(exit_code, output, error)
      msg = "Process #{name} exited with code #{exit_code}"
      cmd = (args = @args) ? "#{name} #{args.join ' '}" : name

      capture_with_options msg do |event|
        event.culprit = cmd
        event.extra.merge!({
          output: output,
          error:  error,
        })
      end
    end

    getter! started_at : Time
    getter! process_status : Process::Status

    delegate :exit_code, :success?,
      to: process_status

    private def run_process(output : IO = IO::Memory.new, error : IO = IO::Memory.new)
      @process_status = Process.run command: name, args: args,
        shell: true,
        input: STDIN,
        output: IO::MultiWriter.new(STDOUT, output),
        error: IO::MultiWriter.new(STDERR, error)
      {output.to_s.chomp, error.to_s.chomp}
    end

    def run : Nil
      configure!
      @started_at = Time.now

      capture_with_options do
        start = Time.monotonic
        output, error = run_process
        running_for = Time.monotonic - start

        context.tags.merge!({
          exit_code: exit_code,
        })
        context.extra.merge!({
          running_for: running_for.to_s,
          started_at:  started_at,
        })

        captured = false
        error.scan CRYSTAL_EXCEPTION_PATTERN do |match|
          msg = match["message"]
          klass = match["class"]
          backtrace = match["backtrace"]
          in_fiber = match["in_fiber"]?
          fiber_name = match["fiber_name"]?
          backtrace = backtrace.gsub /^\s*from\s*/m, ""
          capture_crystal_exception(klass, msg, backtrace, tags: {
            in_fiber:   !!in_fiber,
            fiber_name: fiber_name,
          })
          captured = true
        end
        unless success?
          if error =~ CRYSTAL_CRASH_PATTERN
            msg = $~["message"]
            backtrace = $~["backtrace"]
            capture_crystal_crash(msg, backtrace)
            captured = true
          end
          unless captured
            capture_process_failure(exit_code, output, error)
          end
        end

        exit(exit_code)
      end
    end
  end
end

if ARGV.empty?
  puts "Usage: #{PROGRAM_NAME} <CMD> [OPTION]..."
  exit(1)
end

name, args = ARGV[0], ARGV.size > 1 ? ARGV[1..-1] : nil
handler = Raven::CrashHandler.new(name, args)
handler.raven.tap do |raven|
  raven.configuration.src_path = Dir.current
  raven.user_context({
    username: `whoami`.chomp,
  })
end
handler.run