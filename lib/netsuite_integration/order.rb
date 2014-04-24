module NetsuiteIntegration
  class Order < Base
    attr_reader :config, :collection, :order_payload, :sales_order,
      :existing_sales_order

    def initialize(config, payload = {})
      super(config, payload)

      @config = config
      @order_payload = payload[:order]

      @existing_sales_order = sales_order_service.find_by_external_id(order_payload[:number] || order_payload[:id])

      if existing_sales_order
        @sales_order = NetSuite::Records::SalesOrder.new({
          internal_id: existing_sales_order.internal_id,
          external_id: existing_sales_order.external_id
        })
      else
        @sales_order = NetSuite::Records::SalesOrder.new({
          order_status: '_pendingFulfillment',
          external_id: order_payload[:number] || order_payload[:id]
        })

        # depending on your NS instance a custom form will need to be set to close the sales order
        if (custom_form_id = config['netsuite_sales_order_custom_form_id']).present?
          @sales_order.custom_form = NetSuite::Records::RecordRef.new(internal_id: custom_form_id)
        end
      end
    end

    def imported?
      @existing_sales_order
    end

    def create
      sales_order.entity = set_up_customer
      sales_order.item_list = build_item_list

      # Prevent NetSuite from charging taxes automatically which
      # will cause the sales order total to differ from the order in the Spree store
      sales_order.is_taxable = false

      sales_order.transaction_bill_address = build_bill_address

      sales_order.shipping_cost = order_payload[:totals][:shipping]
      sales_order.transaction_ship_address = build_ship_address

      sales_order.tran_date = order_payload[:placed_on]

      if sales_order.add
        fresh_sales_order = sales_order_service.find_by_external_id(order_payload[:number] || order_payload[:id])
        sales_order.tran_id = fresh_sales_order.tran_id
        # need entity on sales_order for CustomerDeposit.customer
        sales_order.entity = fresh_sales_order.entity
        sales_order
      end
    end

    def update
      sales_order.update(
        item_list: build_item_list,
        transaction_bill_address: build_bill_address,
        shipping_cost: order_payload[:totals][:shipping],
        transaction_ship_address: build_ship_address
      )
    end

    def paid?
      payment_total = order_payload[:payments].sum { |p| p[:amount] }
      order_payload[:totals][:order] <= payment_total
    end

    def errors
      self.sales_order.errors.map(&:message).join(", ")
    end

    private
    def set_up_customer
      if customer = customer_service.find_by_external_id(order_payload[:email])
        if customer.addressbook_list.addressbooks == []
          # update address if missing
          customer_service.update_address(customer, order_payload[:shipping_address])
        end
      else
        customer = customer_service.create(order_payload.dup)
      end

      NetSuite::Records::RecordRef.new(external_id: customer.external_id)
    end

    def build_item_list
      sales_order_items = order_payload[:line_items].map do |item|

        reference = item[:sku] || item[:product_id]
        unless inventory_item = inventory_item_service.find_by_item_id(reference)
          raise NetSuite::RecordNotFound, "Inventory Item \"#{reference}\" not found in NetSuite"
        end

        NetSuite::Records::SalesOrderItem.new({
          item: { internal_id: inventory_item.internal_id },
          quantity: item[:quantity],
          amount: item[:quantity] * item[:price]
        })
      end

      # Due to NetSuite complexity, taxes and discounts will be treated as line items.
      ["tax", "discount", "adjustment"].map do |type|
        value = order_payload[:totals][type] || 0

        if value != 0
          sales_order_items.push(NetSuite::Records::SalesOrderItem.new({
            item: { internal_id: internal_id_for(type) },
            rate: value
          }))
        end
      end

      NetSuite::Records::SalesOrderItemList.new(item: sales_order_items)
    end

    def build_bill_address
      if payload = order_payload[:billing_address]
        NetSuite::Records::BillAddress.new({
          bill_addressee: "#{payload[:firstname]} #{payload[:lastname]}",
          bill_addr1: payload[:address1],
          bill_addr2: payload[:address2],
          bill_zip: payload[:zipcode],
          bill_city: payload[:city],
          bill_state: Services::StateService.by_state_name(payload[:state]),
          bill_country: Services::CountryService.by_iso_country(payload[:country]),
          bill_phone: payload[:phone].gsub(/([^0-9]*)/, "")
        })
      end
    end

    def build_ship_address
      if payload = order_payload[:shipping_address]
        NetSuite::Records::ShipAddress.new({
          ship_addressee: "#{payload[:firstname]} #{payload[:lastname]}",
          ship_addr1: payload[:address1],
          ship_addr2: payload[:address2],
          ship_zip: payload[:zipcode],
          ship_city: payload[:city],
          ship_state: Services::StateService.by_state_name(payload[:state]),
          ship_country: Services::CountryService.by_iso_country(payload[:country]),
          ship_phone: payload[:phone].gsub(/([^0-9]*)/, "")
        })
      end
    end

    def internal_id_for(type)
      name = @config.fetch("netsuite_item_for_#{type}s", "Store #{type.capitalize}")
      non_inventory_item_service.find_or_create_by_name(name).internal_id
    end
  end
end
