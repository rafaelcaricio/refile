require "logger"
require "json"

module Refile
  class App
    def initialize(logger: nil, allow_origin: nil)
      @logger = logger
      @logger ||= ::Logger.new(nil)
      @allow_origin = allow_origin
    end

    class Proxy
      def initialize(peek, file)
        @peek = peek
        @file = file
      end

      def close
        @file.close
      end

      def each(&block)
        block.call(@peek)
        @file.each(&block)
      end
    end

    def call(env)
      @logger.info { "Refile: #{env["REQUEST_METHOD"]} #{env["PATH_INFO"]}" }
      if env["REQUEST_METHOD"] == "GET"
        backend_name, *process_args, id, filename = env["PATH_INFO"].sub(/^\//, "").split("/")
        backend = Refile.backends[backend_name]

        if backend and id
          @logger.debug { "Refile: serving #{id.inspect} from #{backend_name} backend which is of type #{backend.class}" }

          file = backend.get(id)

          unless process_args.empty?
            name = process_args.shift
            unless Refile.processors[name]
              @logger.debug { "Refile: no such processor #{name.inspect}" }
              return not_found
            end
            file = Refile.processors[name].call(file, *process_args)
          end

          peek = begin
            file.read(Refile.read_chunk_size)
          rescue => e
            log_error(e)
            return not_found
          end

          headers = {}
          headers["Access-Control-Allow-Origin"] = @allow_origin if @allow_origin

          [200, headers, Proxy.new(peek, file)]
        else
          @logger.debug { "Refile: must specify backend and id" }
          not_found
        end
      elsif env["REQUEST_METHOD"] == "POST"
        backend_name, *rest = env["PATH_INFO"].sub(/^\//, "").split("/")
        backend = Refile.backends[backend_name]

        return not_found unless rest.empty?
        return not_found unless backend and Refile.direct_upload.include?(backend_name)

        file = backend.upload(Rack::Request.new(env).params.fetch("file").fetch(:tempfile))
        [200, { "Content-Type" => "application/json" }, [{ id: file.id }.to_json]]
      else
        @logger.debug { "Refile: request methods other than GET and POST are not allowed" }
        not_found
      end
    rescue => e
      log_error(e)
      [500, {}, ["error"]]
    end

  private

    def not_found
      [404, {}, ["not found"]]
    end

    def log_error(e)
      if @logger.debug?
        @logger.debug "Refile: unable to read file"
        @logger.debug "#{e.class}: #{e.message}"
        e.backtrace.each do |line|
          @logger.debug "  #{line}"
        end
      end
    end
  end
end
