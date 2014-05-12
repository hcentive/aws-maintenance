require 'aws/deep_symbolizable'

module AWS
  class Configuration

    @_settings = {}
    attr_reader :_settings

    DEFAULTS = {
      'logger' => {
        'home' => '/var/log/aws/',
        'file' => 'ec2.log'
      },

      'mail' => {
        'administrator' => 'satyendra.sharma@hcentive.com'
      },

      'aws' => {
        'shutdown_pre' => 300,
        'tags' => {
          'start_time' => 'starttime',
          'stop_time' => 'stoptime',
          'cost_center' => 'cost-center',
          'stack' => 'stack',
          'owner' => 'owner',
          'name' => 'Name',
          'created_date' => 'created',
          'expiry_date' => 'expires'
        }
      }
    }

    def initialize
      @_settings = DEFAULTS.deep_symbolize
    end

    def load(filename, options = {})
      newsets = SafeYAML.load_file(filename).deep_symbolize
      newsets = newsets[options[:env].to_sym] if \
                                                 options[:env] && \
                                                 newsets[options[:env].to_sym]
      deep_merge(@_settings, newsets)
    end

    # Deep merging of hashes
    # deep_merge by Stefan Rusterholz, see http://www.ruby-forum.com/topic/142809
    def deep_merge(target, data)
      merger = proc{|key, v1, v2|
        Hash === v1 && Hash === v2 ? v1.merge(v2, &merger) : v2 }
      target.merge! data, &merger
    end

    def method_missing(name, *args, &block)
      @_settings[name.to_sym] ||
      fail(NoMethodError, "unknown configuration root #{name}", caller)
    end
  end
end
