module ActiveRecord

  Base.class_eval do

    def self.failover_connection(config)
      adapter_types = config[:failover_adapter].split(/[\s,]+/)
      ActiveRecord::ConnectionAdapters::FailoverAdapter.create_adapter(adapter_types) do
        config[:host].split(/[\s,]+/).zip(adapter_types).map do |host, type|
          type ||= adapter_types.first
          send "#{type}_connection", config.dup.merge(:host => host)
        end
      end.tap do |adapter|
        adapter.reconnect_timeout = config[:failover_reconnect_timeout]
      end
    end

  end

  module ConnectionAdapters

    class FailoverAdapter < AbstractAdapter

      ADAPTER_NAME = 'Failover Adapter'.freeze
      DEFAULT_RECONNECT_TIMEOUT = 60
    
      def initialize(*adapters)
        @adapters = adapters.flatten
        @last_verification = Time.now.to_i
        @reconnect_timeout = DEFAULT_RECONNECT_TIMEOUT
      end

      def reconnect_timeout=(timeout)
        @reconnect_timeout = timeout.to_i if timeout
      end

      def adapter_name #:nodoc:
        ADAPTER_NAME
      end
    
      def active?
        @adapters.any? &:active?
      rescue
        false
      end
    
      def requires_reloading?
        false
      end
    
      %w(reconnect! disconnect! reset! verify!).each do |method|
        class_eval <<-END
          def #{method}(*args, &block)
            @adapters.each { |a| a.#{method}(*args, &block) rescue {} }
            nil
          end
        END
      end
    
      def reset_runtime
        @adapters.inject(0.0) { |total, a| total += a.reset_runtime }
      end
    
      private
    
      def first_active_adapter
        now = Time.now.to_i
        if (now - @last_verification) > @reconnect_timeout
          @adapters.each { |a| a.reconnect! unless a.active? }
          @last_verification = now
        end
        @adapters.detect &:active? or raise ActiveRecordError, "There are no active connections available."
      end
    
      def proxy_adapter_method(method, *args, &block)
        first_active_adapter.send method, *args, &block
      end
    
      # Load given adapter type(s) and mixin connect_with_failover.
      # Returns array of adapter classes
      def self.load_adapter_classes_with_failover(*types)
        types.flatten.map do |type|
          require klass = "active_record/connection_adapters/#{type}_adapter"
          klass.camelize.constantize.tap do |k|
            k.class_eval do
              def connect_with_failover
                connect_without_failover
              rescue Exception => e
                @logger.error(e) if @logger
              end
              alias_method_chain :connect, :failover
            end
          end
        end
      end
    
      # Return all methods for a given class or classes
      def self.all_methods(*classes)
        classes.flatten.map do |c|
          %w(public protected private).map do |level|
            c.send "#{level}_instance_methods", false
          end
        end.flatten.uniq.sort
      end
    
      # Creates a new instance of FailoverAdapter with proxy methods based on the given adapter types.
      # A block is expected which should return an array of adapter instances.
      def self.create_adapter(types, &block)
        adapter_classes = load_adapter_classes_with_failover(types)
        proxy_methods = all_methods(adapter_classes) - all_methods(self)
        Class.new(self) do
          proxy_methods.each do |method_name|
            class_eval <<-END
              def #{method_name}(*args, &block)
                proxy_adapter_method :#{method_name}, *args, &block
              end
            END
          end
        end.new(yield)
      end

    end

  end

end