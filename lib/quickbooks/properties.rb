module Quickbooks
  # Property is primarily defined in property.rb
  class Property
  end
  # Entity is primarily defined in entity.rb
  class Entity < Property
  end
  # EmbeddedEntity is primarily defined in embedded_entity.rb
  class EmbeddedEntity < Entity
  end
  # # EntityCollection is primarily defined in entity.rb
  # class EntityCollection < Entity
  # end
  # # EmbeddedEntities is primarily defined in embedded_entity.rb
  # class EmbeddedEntities < EntityCollection
  # end

  # Some features in here would work better with dynamic inheritance!
  class ClassProperty
    attr_accessor :klass, :options

    def initialize(property_class, options={})
      @klass    = property_class
      @options  = options
    end

    def inspect
      "<Property:#{@klass.class_leaf_name} #{options.inspect.gsub(/\{\}/,'')}>"
    end

    def self.cascade(method,klass_method=nil)
      class_eval "def #{method}; options[:#{method.to_s.gsub(/\?$/,'')}] || @klass.#{klass_method || method} end"
    end
    cascade :writable?
    cascade :name
    cascade :camelized_name
    cascade :instance_variable_name
    cascade :writer_name
    cascade :reader_name
  end

  PropertyIndex = Object.new
  class << PropertyIndex
    def index
      @index ||= Hash.new {|h,k| h[k] = Hash.new {|h,k| h[k] = {}}}
    end
    
    def [](klass,property)
      index[klass][property]
    end
    def []=(klass,property,options)
      index[klass][property] = options
    end
  end

  # Simply defines the way Properties and attributes work. Properties refer to the field names and types for an Entity class,
  # while Attributes refer to the values of those Properties, on instantiated objects.
  module Properties
    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods
      # Register multiple properties at once. For example:
      #   properties ListID, Name
      # All Attributes should be a ValueAttribute or an EntityAttribute
      def properties(*args)
        if args.empty?
          @properties ||= []
        else
          args.each do |prop|
            property, options = prop.is_a?(Array) ? prop : [prop, {}]
            property = ClassProperty.new(property, options)
            properties << property
            class_eval "
              def #{property.writer_name}(v)
                @#{property.instance_variable_name} = #{property.name}.new(v)
              end
              def #{property.reader_name}
                @#{property.instance_variable_name} ||= #{property.name}.new(nil)
              end
            "
          end
        end
      end
      def property_names
        @properties.collect {|p| p.klass.name}
      end

      # Read-only attributes: These are attributes, but not modifiable in Quickbooks
      def read_only
        @properties.reject {|p| p.writable?}
      end
      def read_only_names
        read_only.collect {|p| p.klass.name}
      end

      # Read-write attributes: can be modified and saved back to Quickbooks
      def read_write
        @properties - read_only
      end
      def read_write_names
        read_write.collect {|p| p.klass.name}
      end

      # Instantiate a new object with just attributes, or an existing object replacing the attributes
      def instantiate(obj_or_attrs={},attrs={})
        if obj_or_attrs.is_a?(Property)
          obj = obj_or_attrs
        else
          obj = allocate
          attrs = obj_or_attrs
        end
        # puts "BASE Attributes: #{attrs.inspect}"

        attrs.each do |key,value|
          if obj.respond_to?(Property[key].writer_name)
            obj.send(Property[key].writer_name, value)
            obj.original_values[Property[key].reader_name] = obj.instance_variable_get('@' + Property[key].instance_variable_name).dup rescue nil
          end
        end if attrs
        obj # Will be either a nice object, or a Qbxml::Error object.
      end
    end

    # *** *** *** ***
    # Instance Methods

    def initialize(*args)
      @new_record = true
    end

    # Returns a hash that represents all this object's attributes.
    def attributes(include_read_only=false)
      attrs = {}
      (include_read_only ? self.class.properties : self.class.read_write).each do |column|
        attrs[column.instance_variable_name] = instance_variable_get('@' + column.instance_variable_name)
      end
      attrs
    end

    # Updates all attributes included in _attrs_ to the values given. The object will now be dirty?.
    def attributes=(attrs)
      raise ArgumentError, "attributes can only be set to a hash of attributes" unless attrs.is_a?(Hash)
      attrs.each do |key,value|
        writer_method = key.is_a?(Symbol) ? key.to_s+'=' : Property[key].writer_name
        if self.respond_to?(writer_method)
          self.send(writer_method, value)
        end
      end
    end

    # Returns true if the object is a new object (that doesn't represent an existing object in Quickbooks).
    def new_record?
      @new_record
    end

    # Keeps track of the original values the object had when it was instantiated from a quickbooks response. dirty? and dirty_attributes compare the current values with these ones.
    def original_values
      @original_values || (@original_values = {})
    end

    # Returns true if any attributes have changed since the object was last loaded or updated from Quickbooks.
    def dirty?
      # Concept: For each column that the current model includes, has the value been changed?
      self.new_record? || self.class.read_write.any? do |column|
        self.instance_variable_get('@' + column.instance_variable_name) != original_values[column.reader_name]
      end
    end

    # Returns a hash of the attributes and their (new) values that have been changed since the object was last loaded or updated from Quickbooks.
    # If you send in some attributes, it will compare to those given instead of original_attributes.
    def dirty_attributes(compare={},camelized_keys=false)
      compare = original_values if compare.empty?
      pairs = {}
      self.class.read_write.each do |property|
        value = instance_variable_get('@' + property.instance_variable_name)
        pairs[camelized_keys ? property.camelized_name : property.reader_name] = value if value != compare[property.reader_name]
      end
      pairs
    end

    def to_dirty_hash(camelized_keys=false)
      hsh = SlashedHash.new.ordered!(self.class.read_write.stringify_values)
      self.dirty_attributes({}, camelized_keys).each do |key,value|
        hsh[key] = value.is_a?(Quickbooks::Entity) ? value.to_dirty_hash : value
      end
      hsh
    end

    def to_hash(include_read_only=false)
      hsh = SlashedHash.new.ordered!((include_read_only ? self.class.property_names : self.class.read_write_names).stringify_values)
      self.attributes(include_read_only).each do |key,value|
        hsh[key] = value.is_a?(Quickbooks::Entity) ? value.to_hash(include_read_only) : value
      end
      hsh
    end

    def ==(other)
      return false unless other.is_a?(self.class)
      !self.class.read_write.any? do |property|
        self.instance_variable_get('@' + property.instance_variable_name) != other.instance_variable_get('@' + property.instance_variable_name)
      end
    end

    def ===(other)
      # other could be a hash
      if other.is_a?(Hash)
        self == self.class.new(other)
      else
        self == other
      end
    end
    # *** *** *** ***
  end
end