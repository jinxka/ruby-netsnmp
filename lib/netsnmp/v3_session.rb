# frozen_string_literal: true

module NETSNMP
  # Abstraction for the v3 semantics.
  class V3Session < Session
    # @param [String, Integer] version SNMP version (always 3)
    def initialize(context: "", **opts)
      @context = context
      @security_parameters = opts.delete(:security_parameters)
      super
      @message_serializer = Message.new(**opts)
    end

    # @see {NETSNMP::Session#build_pdu}
    #
    # @return [NETSNMP::ScopedPDU] a pdu
    def build_pdu(type, *vars)
      engine_id = security_parameters.engine_id
      ScopedPDU.build(type, headers: [engine_id, @context], varbinds: vars)
    end

    # @see {NETSNMP::Session#send}
    def send(pdu)
      log { "sending request..." }
      encoded_request = encode(pdu)
      encoded_response = @transport.send(encoded_request)
      response_pdu, *args = decode(encoded_response)
      if response_pdu.type == 8
        varbind = response_pdu.varbinds.first
        if varbind.oid == "1.3.6.1.6.3.15.1.1.2.0" # IdNotInTimeWindow
          _, @engine_boots, @engine_time = args
          raise IdNotInTimeWindowError, "request timestamp is already out of time window"
        end
      end
      response_pdu
    end

    private

    def validate(**options)
      super
      if (s = @security_parameters)
        # inspect public API
        unless s.respond_to?(:encode) &&
               s.respond_to?(:decode) &&
               s.respond_to?(:sign)   &&
               s.respond_to?(:verify)
          raise Error, "#{s} doesn't respect the sec params public API (#encode, #decode, #sign)"
        end
      else
        @security_parameters = SecurityParameters.new(security_level: options[:security_level],
                                                      username:       options[:username],
                                                      auth_protocol:  options[:auth_protocol],
                                                      priv_protocol:  options[:priv_protocol],
                                                      auth_password:  options[:auth_password],
                                                      priv_password:  options[:priv_password])

      end
    end

    def security_parameters
      @security_parameters.engine_id = probe_for_engine if @security_parameters.must_revalidate?
      @security_parameters
    end

    # sends a probe snmp v3 request, to get the additional info with which to handle the security aspect
    #
    def probe_for_engine
      report_sec_params = SecurityParameters.new(security_level: 0,
                                                 username: @security_parameters.username)
      pdu = ScopedPDU.build(:get, headers: [])
      log { "sending probe..." }
      encoded_report_pdu = @message_serializer.encode(pdu, security_parameters: report_sec_params)

      encoded_response_pdu = @transport.send(encoded_report_pdu)

      _, engine_id, @engine_boots, @engine_time = decode(encoded_response_pdu, security_parameters: report_sec_params)
      engine_id
    end

    def encode(pdu)
      @message_serializer.encode(pdu, security_parameters: @security_parameters,
                                      engine_boots: @engine_boots,
                                      engine_time: @engine_time)
    end

    def decode(stream, security_parameters: @security_parameters)
      @message_serializer.decode(stream, security_parameters: security_parameters)
    end
  end
end
