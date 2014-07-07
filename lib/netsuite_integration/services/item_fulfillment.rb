module NetsuiteIntegration
  module Services
    class ItemFulfillment < Base
      def latest
        @latest ||= search.sort_by { |item| item.last_modified_date.utc }
      end

      private
        def search
          NetSuite::Records::ItemFulfillment.search({
            criteria: {
              basic: [
                {
                  field: 'type',
                  operator: 'anyOf',
                  type: 'SearchEnumMultiSelectField',
                  value: ["_itemFulfillment"]
                },
                {
                  field: 'lastModifiedDate',
                  type: 'SearchDateField',
                  operator: 'within',
                  value: [
                    last_updated_after,
                    time_now.iso8601
                  ]
                }
              ]
            },
            preferences: {
              pageSize: 1000,
              bodyFieldsOnly: false
            }
          }).results
        end

        def time_now
          Time.now.utc
        end

        def last_updated_after
          Time.parse(config.fetch("netsuite_poll_fulfillment_timestamp")).iso8601
        end
    end
  end
end
