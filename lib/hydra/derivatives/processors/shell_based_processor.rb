# An abstract class for asyncronous jobs that transcode files using FFMpeg

require 'tmpdir'
require 'posix-spawn'

module Hydra::Derivatives::Processors
  module ShellBasedProcessor
    extend ActiveSupport::Concern

    BLOCK_SIZE = 1024

    included do
      class_attribute :timeout
    end

    def process
      name = directives.fetch(:label)
      format = directives[:format]
      raise ArgumentError, "You must provide the :format you want to transcode into. You provided #{directives}" unless format
      # TODO if the source is in the correct format, we could just copy it and skip transcoding.
      encode_file(format, options_for(format))
    end

    # override this method in subclass if you want to provide specific options.
    # returns a hash of options that the specific processors use
    def options_for(format)
      {}
    end

    def encode_file(file_suffix, options)
      out_file = nil
      temp_file_name = output_file(file_suffix)
      self.class.encode(source_path, options, temp_file_name)
      output_file_service.call(File.open(temp_file_name, 'rb'), directives)
      File.unlink(temp_file_name)
    end

    def output_file(file_suffix)
      Dir::Tmpname.create(['sufia', ".#{file_suffix}"], Hydra::Derivatives.temp_file_base){}
    end

    module ClassMethods

      def execute(command)
        context = {}
        if timeout
          execute_with_timeout(timeout, command, context)
        else
          execute_without_timeout(command, context)
        end
      end

      def execute_with_timeout(timeout, command, context)
        begin
          status = Timeout::timeout(timeout) do
            execute_without_timeout(command, context)
          end
        rescue Timeout::Error => ex
          pid = context[:pid]
          Process.kill("KILL", pid)
          raise Hydra::Derivatives::TimeoutError, "Unable to execute command \"#{command}\"\nThe command took longer than #{timeout} seconds to execute"
        end

      end

      def execute_without_timeout(command, context)
        stdout, stderr, status = execute_posix_spawn(*command)
        raise "Unable to execute command \"#{command}\"\n#{stderr}" unless status.exitstatus  == 0
      end

      def execute_posix_spawn(*command)
        pid, stdin, stdout, stderr = POSIX::Spawn.popen4(*command)
        Process.waitpid(pid)

        [stdout.read, stderr.read, $?]
      end
    end
  end
end
