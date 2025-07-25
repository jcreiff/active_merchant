module ActiveMerchant # :nodoc:
  module Billing # :nodoc:
    class MercadoPagoGateway < Gateway
      version 'v1'

      self.live_url = self.test_url = "https://api.mercadopago.com/#{fetch_version}"

      self.supported_countries = %w[AR BR CL CO MX PE UY]
      self.supported_cardtypes = %i[visa master american_express elo cabal naranja creditel patagonia_365 tarjeta_sol]

      self.homepage_url = 'https://www.mercadopago.com/'
      self.display_name = 'Mercado Pago'
      self.money_format = :dollars

      def initialize(options = {})
        requires!(options, :access_token)
        super
      end

      def purchase(money, payment, options = {})
        MultiResponse.run do |r|
          r.process { commit('tokenize', 'card_tokens', card_token_request(money, payment, options)) }
          options[:card_token] = r.authorization.split('|').first
          r.process { commit('purchase', 'payments', purchase_request(money, payment, options)) }
        end
      end

      def authorize(money, payment, options = {})
        MultiResponse.run do |r|
          r.process { commit('tokenize', 'card_tokens', card_token_request(money, payment, options)) }
          options[:card_token] = r.authorization.split('|').first
          r.process { commit('authorize', 'payments', authorize_request(money, payment, options)) }
        end
      end

      def capture(money, authorization, options = {})
        post = {}
        authorization, = authorization.split('|')
        post[:capture] = true
        post[:transaction_amount] = amount(money).to_f
        commit('capture', "payments/#{authorization}", post)
      end

      def refund(money, authorization, options = {})
        post = {}
        authorization, original_amount = authorization.split('|')
        post[:amount] = amount(money).to_f if original_amount && original_amount.to_f > amount(money).to_f
        add_idempotency_key(post, options)
        commit('refund', "payments/#{authorization}/refunds", post)
      end

      def void(authorization, options = {})
        authorization, = authorization.split('|')
        post = { status: 'cancelled' }
        commit('void', "payments/#{authorization}", post)
      end

      def verify(credit_card, options = {})
        verify_amount = 100
        verify_amount = options[:amount].to_i if options[:amount]
        MultiResponse.run(:use_first_response) do |r|
          r.process { authorize(verify_amount, credit_card, options) }
          r.process(:ignore_result) { void(r.authorization, options) }
        end
      end

      def inquire(authorization, options = {})
        commit('inquire', inquire_path(authorization, options), {})
      end

      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        transcript.
          gsub(%r((access_token=).*?([^\s]+)), '\1[FILTERED]').
          gsub(%r((\"card_number\\\":\\\")\d+), '\1[FILTERED]').
          gsub(%r((\"security_code\\\":\\\")\d+), '\1[FILTERED]')
      end

      private

      def card_token_request(money, payment, options = {})
        post = {}
        post[:card_number] = payment.number
        post[:security_code] = payment.verification_value
        post[:expiration_month] = payment.month
        post[:expiration_year] = payment.year
        post[:cardholder] = {
          name: format_name(payment.name),
          identification: {
            type: options[:cardholder_identification_type],
            number: options[:cardholder_identification_number]
          }
        }
        post
      end

      def purchase_request(money, payment, options = {})
        post = {}
        add_invoice(post, money, options)
        add_payment(post, options)
        add_additional_data(post, options)
        add_customer_data(post, payment, options)
        add_address(post, options)
        add_processing_mode(post, options)
        add_net_amount(post, options)
        add_taxes(post, options)
        add_notification_url(post, options)
        add_idempotency_key(post, options)
        add_3ds(post, options)
        post[:binary_mode] = options.fetch(:binary_mode, true) unless options[:execute_threed]
        post
      end

      def authorize_request(money, payment, options = {})
        post = purchase_request(money, payment, options)
        post[:capture] = options[:capture] || false
        post
      end

      def add_processing_mode(post, options)
        return unless options[:processing_mode]

        post[:processing_mode] = options[:processing_mode]
        post[:merchant_account_id] = options[:merchant_account_id] if options[:merchant_account_id]
        post[:payment_method_option_id] = options[:payment_method_option_id] if options[:payment_method_option_id]
        add_merchant_services(post, options)
      end

      def add_merchant_services(post, options)
        return unless options[:fraud_scoring] || options[:fraud_manual_review]

        merchant_services = {}
        merchant_services[:fraud_scoring] = options[:fraud_scoring] if options[:fraud_scoring]
        merchant_services[:fraud_manual_review] = options[:fraud_manual_review] if options[:fraud_manual_review]
        post[:merchant_services] = merchant_services
      end

      def add_additional_data(post, options)
        post[:sponsor_id] = options[:sponsor_id] unless test?
        post[:metadata] = options[:metadata] if options[:metadata]
        post[:device_id] = options[:device_id] if options[:device_id]
        post[:additional_info] = {
          ip_address: options[:ip_address]
        }.merge(options[:additional_info] || {})

        add_address(post, options)
        add_shipping_address(post, options)
      end

      def add_customer_data(post, payment, options)
        post[:payer] = {
          email: options[:email],
          first_name: format_name(payment.first_name),
          last_name: format_name(payment.last_name)
        }.merge(options[:payer] || {})
      end

      def add_address(post, options)
        if address = (options[:billing_address] || options[:address])

          post[:additional_info].merge!({
            payer: {
              address: {
                zip_code: address[:zip],
                street_name: "#{address[:address1]} #{address[:address2]}"
              }
            }
          })
        end
      end

      def add_shipping_address(post, options)
        if address = options[:shipping_address]

          post[:additional_info].merge!({
            shipments: {
              receiver_address: {
                zip_code: address[:zip],
                street_name: "#{address[:address1]} #{address[:address2]}"
              }
            }
          })
        end
      end

      def split_street_address(address1)
        street_number = address1.split(' ').first

        if street_name = address1.split(' ')[1..-1]
          street_name = street_name.join(' ')
        else
          nil
        end

        [street_number, street_name]
      end

      def add_invoice(post, money, options)
        post[:transaction_amount] = amount(money).to_f
        post[:description] = options[:description]
        post[:installments] = options[:installments] ? options[:installments].to_i : 1
        post[:statement_descriptor] = options[:statement_descriptor] if options[:statement_descriptor]
        post[:external_reference] = options[:order_id] || options[:external_reference] || SecureRandom.hex(16)
      end

      def add_payment(post, options)
        post[:token] = options[:card_token]
        post[:issuer_id] = options[:issuer_id] if options[:issuer_id]
        post[:payment_method_id] = options[:payment_method_id] if options[:payment_method_id]
      end

      def add_net_amount(post, options)
        post[:net_amount] = Float(options[:net_amount]) if options[:net_amount]
      end

      def add_idempotency_key(post, options)
        post[:idempotency_key] = options[:idempotency_key] if options[:idempotency_key]
      end

      def add_notification_url(post, options)
        post[:notification_url] = options[:notification_url] if options[:notification_url]
      end

      def add_taxes(post, options)
        return unless (tax_object = options[:taxes])

        if tax_object.is_a?(Array)
          post[:taxes] = process_taxes_array(tax_object)
        elsif tax_object.is_a?(Hash)
          post[:taxes] = process_taxes_hash(tax_object)
        else
          raise taxes_error
        end
      end

      def process_taxes_hash(tax_object)
        [sanitize_taxes_hash(tax_object)]
      end

      def process_taxes_array(taxes_array)
        taxes_array.map do |tax_object|
          raise taxes_error unless tax_object.is_a?(Hash)

          sanitize_taxes_hash(tax_object)
        end
      end

      def sanitize_taxes_hash(tax_object)
        tax_value = tax_object['value'] || tax_object[:value]
        tax_type = tax_object['type'] || tax_object[:type]

        raise taxes_error if tax_value.nil? || tax_type.nil?

        { value: Float(tax_value), type: tax_type }
      end

      def taxes_error
        ArgumentError.new("Taxes should be a single object or array of objects with the shape: { value: 500, type: 'IVA' }")
      end

      def parse(body)
        JSON.parse(body)
      rescue JSON::ParserError
        {
          'status' => 'error',
          'status_detail' => 'json_parse_error',
          'message' => "A non-JSON response was received from Mercado Pago where one was expected. The raw response was:\n\n#{body}"
        }
      end

      def commit(action, path, parameters)
        if %w[capture void].include?(action)
          response = parse(ssl_request(:put, url(path), post_data(parameters), headers))
        elsif action == 'inquire'
          response = parse(ssl_get(url(path), headers))

          response = response[0]['results'][0] if response.is_a?(Array)
        else
          response = parse(ssl_post(url(path), post_data(parameters), headers(parameters)))
        end

        Response.new(
          success_from(action, response),
          message_from(response),
          response,
          authorization: authorization_from(response, parameters),
          test: test?,
          error_code: error_code_from(action, response)
        )
      end

      def success_from(action, response)
        if action == 'refund'
          response['status'] != 404 && response['error'].nil?
        else
          %w[active approved authorized cancelled in_process pending].include?(response['status'])
        end
      end

      def message_from(response)
        (response['status_detail']) || (response['message'])
      end

      def authorization_from(response, params)
        [response['id'], params[:transaction_amount]].join('|')
      end

      def post_data(parameters = {})
        params = parameters.clone.tap do |p|
          p.delete(:device_id)
          p.delete(:idempotency_key)
        end
        params.to_json
      end

      def inquire_path(authorization, options)
        if authorization
          authorization, = authorization.split('|')
          "payments/#{authorization}"
        else
          "payments/search?external_reference=#{options[:order_id] || options[:external_reference]}"
        end
      end

      def error_code_from(action, response)
        unless success_from(action, response)
          if cause = response['cause']
            cause.empty? ? nil : cause.first['code']
          else
            response['status']
          end
        end
      end

      def add_3ds(post, options)
        return unless options[:execute_threed]

        post[:three_d_secure_mode] = options[:three_ds_mode] == 'mandatory' ? 'mandatory' : 'optional'
        post[:notification_url] = options[:notification_url] if options[:notification_url]
      end

      def url(action)
        full_url = (test? ? test_url : live_url)
        full_url + "/#{action}?access_token=#{CGI.escape(@options[:access_token])}"
      end

      def headers(options = {})
        headers = {
          'Content-Type' => 'application/json'
        }
        headers['X-meli-session-id'] = options[:device_id] if options[:device_id]
        headers['X-Idempotency-Key'] = options[:idempotency_key] if options[:idempotency_key]
        headers
      end

      def handle_response(response)
        case response.code.to_i
        when 200..499
          response.body
        else
          raise ResponseError.new(response)
        end
      end
    end
  end
end
