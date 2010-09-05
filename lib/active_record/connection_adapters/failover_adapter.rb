module ActiveRecord

  class Base

    def self.failover_connection(config)
      ActiveRecord::ConnectionAdapters::FailoverAdapter.establish_connection(config)
    end

  end

  module ConnectionAdapters

    class FailoverAdapter < AbstractAdapter

      ADAPTER_NAME = 'Failover Adapter'.freeze
      DEFAULT_RECONNECT_TIMEOUT = 60
      PROXY_ATTEMPTS = 2
    
      def initialize(adapters, reconnect_timeout=nil)
        @adapters = adapters.flatten
        @reconnect_timeout = (reconnect_timeout || DEFAULT_RECONNECT_TIMEOUT).to_i
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

      # Avoid calling active? a ridiculous number of times by only checking active?
      # status once within @reconnect_timeout window
      def first_active_adapter
        now = Time.now.to_i
        unless @first_active_adapter and (now - @last_verification) < @reconnect_timeout
          @first_active_adapter = @adapters.detect do |a|
            a.reconnect! unless active = a.active?
            active
          end
          @last_verification = now
        end
        @first_active_adapter or raise ActiveRecordError, "There are no active connections available."
      end

      # Proxies an adapter method call to the first active adapter.  If that fails,
      # a subsequent attempts will be made on the next active adapter.
      def proxy_adapter_method(method, *args, &block)
        (1..PROXY_ATTEMPTS).each do
          adapter = first_active_adapter
          begin
            return adapter.send method, *args, &block
          rescue Exception => e
            # On failure, check to see if the adapter is even active.  If it isn't, try again on next active adapter.
            raise e if adapter.active?
            @first_active_adapter = nil
          end
        end
      end

      # Mixes in connect_with_failover to adapter class
      def self.mixin_adapter_class_with_failover(klass)
        # Make sure and only patch once 
        unless klass.method_defined? :connect_with_failover
          klass.class_eval do
            def connect_with_failover
              connect_without_failover
            rescue Exception => e
              @logger.error(e) if @logger
            end
            alias_method_chain :connect, :failover
          end
        end
        klass
      end
    
      # Load given adapter type(s) and mixin connect_with_failover.
      # Returns array of adapter classes
      def self.load_adapter_classes_with_failover(*types)
        types.flatten.map do |type|
          require klass = "active_record/connection_adapters/#{type}_adapter"
          mixin_adapter_class_with_failover(klass.camelize.constantize)
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
    
      # Creates a new class of FailoverAdapter with proxy methods based on the given adapter types.
      def self.create_adapter_class(types)
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
        end
      end

      # Creates internal adapter instances for each host specified (using the corresponding type)
      def self.establish_internal_connections(hosts, types, config)
        hosts.zip(types).map do |host, type|
          ActiveRecord::Base.send "#{type || types.first}_connection", config.dup.merge(:host => host)
        end
      end

      # Creates a new instance of the Failover Adapter based on the given config
      def self.establish_connection(config)
        hosts, types = [:host, :failover_adapter].map { |k| config[k].split /[\s,]+/ }
        create_adapter_class(types).new(
          establish_internal_connections(hosts, types, config),
          config[:failover_reconnect_timeout]
        )
      end

    end

  end

end