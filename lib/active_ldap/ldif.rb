# Experimental work-in-progress LDIF implementation.
# Don't care this file for now.

require "strscan"
require "base64"
require "uri"
require "open-uri"

module ActiveLdap
  class Ldif
    include GetTextSupport

    class Parser
      include GetTextSupport

      attr_reader :ldif
      def initialize(source)
        @ldif = nil
        source = source.to_s if source.is_a?(LDIF)
        @source = source
      end

      ATTRIBUTE_TYPE_CHARS = /[a-zA-Z][a-zA-Z0-9\-]*/
      SAFE_CHAR = /[\x01-\x09\x0B-\x0C\x0E-\x7F]/
      SAFE_INIT_CHAR = /[\x01-\x09\x0B-\x0C\x0E-\x1F\x21-\x39\x3B\x3D-\x7F]/
      SAFE_STRING = /#{SAFE_INIT_CHAR}#{SAFE_CHAR}*/
      def parse
        return @ldif if @ldif

        @scanner = Scanner.new(@source)
        raise version_spec_is_missing unless @scanner.scan(/version:/)
        @scanner.scan(/\s*/)

        version = @scanner.scan(/\d+/)
        raise version_number_is_missing if version.nil?

        version = Integer(version)
        raise unsupported_version(version) if version != 1

        raise separator_is_missing unless @scanner.scan_separators

        records = parse_records

        @ldif = LDIF.new(version, records)
      end

      private
      def read_base64_value
        value = @scanner.scan(/[a-zA-Z0-9\+\/=]+/)
        raise base64_encoded_value_is_missing if value.nil?

        Base64.decode64(value).chomp
      end

      def read_external_file
        uri_string = @scanner.scan(URI::REGEXP::ABS_URI)
        raise uri_is_missing if uri_string.nil?
        uri = nil
        begin
          uri = URI.parse(uri_string)
        rescue URI::Error
          raise invalid_uri(uri_string, $!.message)
        end

        if uri.scheme == "file"
          File.open(uri.path, "rb").read
        else
          uri.read
        end
      end

      def parse_dn(dn_string)
        DN.parse(dn_string).to_s
      rescue DistinguishedNameInvalid
        invalid_dn(dn_string, $!.reason)
      end

      def parse_attributes
        attributes = {}
        type, options, value = parse_attribute
        attributes[type] = [value]
        while @scanner.scan_separator
          break if @scanner.scan_separator or @scanner.eos?
          type, options, value = parse_attribute
          attributes[type] ||= []
          container = attributes[type]
          options.each do |option|
            parent = container.find do |val|
              val.is_a?(Hash) and val.has_key?(option)
            end
            if parent.nil?
              parent = {option => []}
              container << parent
            end
            container = parent[option]
          end
          container << value
        end
        attributes
      end

      def parse_attribute
        type = @scanner.scan(ATTRIBUTE_TYPE_CHARS)
        raise attribute_type_is_missing if type.nil?
        options = parse_options
        value = parse_attribute_value
        [type, options, value]
      end

      def parse_options
        options = []
        while @scanner.scan(/;/)
          option = @scanner.scan(ATTRIBUTE_TYPE_CHARS)
          raise option_is_missing if option.nil?
          options << option
        end
        options
      end

      def parse_attribute_value(accept_external_file=true)
        raise attribute_value_separator_is_missing if @scanner.scan(/:/).nil?
        if @scanner.scan(/:/)
          @scanner.scan(/\s*/)
          read_base64_value
        elsif accept_external_file and @scanner.scan(/</)
          @scanner.scan(/\s*/)
          read_external_file
        else
          @scanner.scan(/\s*/)
          @scanner.scan(/#{SAFE_STRING}?/)
        end
      end

      def parse_control
        return nil if @scanner.scan(/control:/).nil?
        @scanner.scan(/\s*/)
        oid = @scanner.scan(/\d+(?:\.\d+)?/)
        raise oid_is_missing if oid.nil?
        criticality = nil
        if @scanner.scan(/\s+/)
          criticality = @scanner.scan(/true|false/)
          raise criticality_is_missing if criticality.nil?
        end
        value = parse_attribute_value if @scanner.peek(/:/)
        raise separator_is_missing unless @scanner.scan_separator
        [oid, criticality, value]
      end

      def parse_controls
        controls = []
        loop do
          control = parse_control
          break if control.nil?
          controls << control
        end
        controls
      end

      def parse_change_type
        return nil unless @scanner.scan(/changetype:\s*/)
        type = @scanner.scan(/add|delete|modrdn|moddn|modify/)
        raise change_type_is_missing if type.nil?

        raise separator_is_missing unless @scanner.scan_separator
        type
      end

      def parse_modify_rdn_record(dn, controls)
        raise newrdn_mark_is_missing unless @scanner.scan(/newrdn\b/)
        new_rdn = parse_attribute_value(false)
        raise separator_is_missing unless @scanner.scan_separator

        unless @scanner.scan(/deleteoldrdn:/)
          raise delete_old_rdn_mark_is_missing
        end
        @scanner.scan(/\s*/)
        delete_old_rdn = @scanner.scan(/[01]/)
        raise delete_old_rdn_value_is_missing if delete_old_rdn.nil?
        raise separator_is_missing unless @scanner.scan_separator

        if @scanner.scan(/newsuperior:/)
          @scanner.scan(/\s*/)
          new_superior = parse_attribute_value(false)
          raise new_superior_value_is_missing if new_superior.nil?
          new_superior = parse_dn(new_superior)
          raise separator_is_missing unless @scanner.scan_separator
        end
        ModifyRDNRecord.new(dn, controls, new_rdn, delete_old_rdn, new_superior)
      end

      def parse_change_type_record(dn, controls, change_type)
        case change_type
        when "add"
          attributes = parse_attributes
          AddRecord.new(dn, controls, attributes)
        when "delete"
          DeleteRecord.new(dn, controls)
        when "modrdn"
          parse_modify_rdn_record(dn, controls)
        else
          raise unknown_change_type(change_type)
        end
      end

      def parse_record
        raise dn_mark_is_missing unless @scanner.scan(/dn:/)
        if @scanner.scan(/:\s*/)
          dn = parse_dn(read_base64_value)
        else
          @scanner.scan(/\s*/)
          dn = @scanner.scan(/.+$/)
          raise dn_is_missing if dn.nil?
          dn = parse_dn(dn)
        end

        raise separator_is_missing unless @scanner.scan_separators

        controls = parse_controls
        change_type = parse_change_type
        raise change_type_is_missing if change_type.nil? and !controls.empty?

        if change_type
          parse_change_type_record(dn, controls, change_type)
        else
          attributes = parse_attributes
          ContentRecord.new(dn, attributes)
        end
      end

      def parse_records
        records = []
        records << parse_record
        until @scanner.eos?
          records << parse_record
        end
        records
      end

      def invalid_ldif(reason)
        LdifInvalid.new(@source, reason, @scanner.line, @scanner.column)
      end

      def version_spec_is_missing
        invalid_ldif(_("version spec is missing"))
      end

      def version_number_is_missing
        invalid_ldif(_("version number is missing"))
      end

      def unsupported_version(version)
        invalid_ldif(_("unsupported version: %d") % version)
      end

      def separator_is_missing
        invalid_ldif(_("separator is missing"))
      end

      def dn_mark_is_missing
        invalid_ldif(_("'dn:' is missing"))
      end

      def dn_is_missing
        invalid_ldif(_("DN is missing"))
      end

      def invalid_dn(dn_string, reason)
        invalid_ldif(_("DN is invalid: %s: %s") % [dn_string, reason])
      end

      def base64_encoded_value_is_missing
        invalid_ldif(_("Base64 encoded value is missing"))
      end

      def attribute_type_is_missing
        invalid_ldif(_("attribute type is missing"))
      end

      def option_is_missing
        invalid_ldif(_("option is missing"))
      end

      def attribute_value_separator_is_missing
        invalid_ldif(_("':' is missing"))
      end

      def invalid_uri(uri_string, message)
        invalid_ldif(_("URI is invalid: %s: %s") % [uri_string, message])
      end
    end

    class Scanner
      SEPARATOR = /(?:\r\n|\n)/

      def initialize(source)
        @source = source
        @scanner = StringScanner.new(@source)
        @sub_scanner = next_segment || StringScanner.new("")
      end

      def scan(regexp)
        @sub_scanner = next_segment if @sub_scanner.eos?
        @sub_scanner.scan(regexp)
      end

      def peek(regexp)
        @sub_scanner = next_segment if @sub_scanner.eos?
        @sub_scanner.peek(regexp)
      end

      def scan_separator
        return @scanner.scan(SEPARATOR) if @sub_scanner.eos?

        scan(SEPARATOR)
      end

      def scan_separators
        return @scanner.scan(/#{SEPARATOR}+/) if @sub_scanner.eos?

        sub_result = scan(/#{SEPARATOR}+/)
        return nil if sub_result.nil?

        result = @scanner.scan(/#{SEPARATOR}+/)
        return sub_result if result.nil?

        sub_result + result
      end

      def [](*args)
        @sub_scanner[*args]
      end

      def eos?
        @sub_scanner = next_segment if @sub_scanner.eos?
        @sub_scanner.eos? and @scanner.eos?
      end

      def line
        _consumed_source = consumed_source
        return 1 if _consumed_source.empty?

        n = _consumed_source.to_a.size
        n += 1 if _consumed_source[-1, 1] == "\n"
        n
      end

      def column
        _consumed_source = consumed_source
        return 1 if _consumed_source.empty?

        position - (_consumed_source.rindex("\n") || -1)
      end

      def position
        @scanner.pos - (@sub_scanner.string.length - @sub_scanner.pos)
      end

      private
      def next_segment
        loop do
          segment = @scanner.scan(/.+(?:#{SEPARATOR} .*)*#{SEPARATOR}?/)
          return @sub_scanner if segment.nil?
          next if segment[0, 1] == "#"
          return StringScanner.new(segment.gsub(/\r?\n /, ''))
        end
      end

      def consumed_source
        @source[0,  position]
      end
    end

    class << self
      def parse(ldif)
        Parser.new(ldif).parse
      end
    end

    attr_reader :version, :records
    def initialize(version, records)
      @version = version
      @records = records
    end

    class Record
      attr_reader :dn, :attributes
      def initialize(dn, attributes)
        @dn = dn
        @attributes = attributes
      end

      def to_hash
        attributes.merge({"dn" => dn})
      end
    end

    class ContentRecord < Record
    end

    class ChangeRecord < Record
      attr_reader :controls, :change_type
      def initialize(dn, attributes, controls, change_type)
        super(dn, attributes)
        @controls = controls
        @change_type = change_type
      end

      def add?
        @change_type == "add"
      end

      def delete?
        @change_type == "delete"
      end

      def modify?
        @change_type == "modify"
      end

      def modify_dn?
        @change_type == "moddn"
      end

      def modify_rdn?
        @change_type == "modrdn"
      end
    end

    class AddRecord < ChangeRecord
      def initialize(dn, controls, attributes)
        super(dn, attributes, controls, "add")
      end
    end

    class DeleteRecord < ChangeRecord
      def initialize(dn, controls)
        super(dn, {}, controls, "delete")
      end
    end

    class ModifyRDNRecord < ChangeRecord
      attr_reader :new_rdn, :new_superior
      def initialize(dn, controls, new_rdn, delete_old_rdn, new_superior)
        super(dn, {}, controls, "modrdn")
        @new_rdn = new_rdn
        @delete_old_rdn = delete_old_rdn
        @new_superior = new_superior
      end

      def delete_old_rdn?
        @delete_old_rdn
      end
    end
  end

  LDIF = Ldif
end