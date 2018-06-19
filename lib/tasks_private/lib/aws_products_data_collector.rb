# frozen_string_literal: true

require 'uri'
require 'json'
require 'digest'
require 'net/http'
require 'active_support/i18n'
require 'active_support/cache/file_store'
require 'active_support/core_ext/hash/slice'
require 'active_support/core_ext/array/wrap'
require_relative 'simple_logging'

class AwsProductsDataCollector
  OFFERS_HOSTNAME = 'https://pricing.us-east-1.amazonaws.com'
  CACHE = ActiveSupport::Cache::FileStore.new(
    Rails.root.join('tmp/aws_cache/products_data_collector'))
  I18n.backend = I18n.backend.backend # workaround
  CACHE.logger = Logger.new(STDOUT)

  attr_reader *%i(
    service_name
    product_families
    product_attributes
    folding_attributes
    mutable_attributes
  )

  def initialize(service_name:,
                 product_families:,
                 product_attributes:,
                 folding_attributes:,
                 mutable_attributes: nil)

    @service_name       = service_name
    @product_families   = Array.wrap(product_families).dup.freeze
    @product_attributes = Array.wrap(product_attributes).dup.freeze
    @mutable_attributes = Array.wrap(mutable_attributes).dup.freeze
    @folding_attributes = Array.wrap(folding_attributes).dup.freeze
    @product_attributes = (@folding_attributes + @product_attributes).uniq.freeze
  end

  def offers_index_uri
    @offers_index_uri ||=
      URI("#{OFFERS_HOSTNAME}/offers/v1.0/aws/#{service_name}/index.json")
  end

  # offers_index['currentVersion'] # TODO: product['currentGeneration']
  def offers_index
    @offers_index ||= CACHE.fetch("offers_index_#{service_name}", :expires_in => 1.week) do
      JSON.parse(Net::HTTP.get_response(offers_index_uri).body)
    end
  end

  def offer_versions
    @offer_versions ||=
      offers_index['versions'].sort.to_h.freeze
  end

  def offer_versions_cache_key
    @offer_versions_cache_key ||=
      offer_versions.each_key.with_object(Digest::SHA1.new) do |version, digest|
        digest << version
      end.hexdigest
  end

  def offers_version_uri(version_data)
    URI("#{OFFERS_HOSTNAME}#{version_data['offerVersionUrl']}")
  end

  def offers_data
    @offers_data ||= CACHE.fetch("ec2_offers_summary.#{offer_versions_cache_key}") do
      offer_versions.map do |version_name, version_data|
        CACHE.fetch("ec2_offers.#{version_name}") do
          offers_uri = offers_version_uri(version_data)
          json_text = Net::HTTP.get_response(offers_uri).body
          JSON.parse(json_text)['products'].values
        end
      end.reduce(&:+)
    end
  end

  def products_data
    @products_data ||= begin
      result, warnings = CACHE.fetch("ec2_products_summary.#{offer_versions_cache_key}") do
        offers_data.each_with_object([{}, {}]) do |product, (memo, deviations)|
          next unless product_families.include?(product['productFamily'])

          item_attrs  = product['attributes'].slice(*product_attributes)
          items_group = item_attrs.fetch_values(*folding_attributes)

          group_data = memo[items_group] ||= {}
          group_data.merge!(item_attrs) do |key, old_value, new_value|
            unless old_value.casecmp(new_value).zero? || mutable_attributes.include?(key)
              values = (deviations[items_group] ||= {})[key] ||= Set[old_value]
              values << new_value
            end
            new_value # versions are sorted, taking the freshest value
          end
        end
      end

      warn do
        warnings.sort!
        lines = []
        lines << 'Attention! Contradictory products data:'
        lines += warnings.map do |group, attrs|
          attrs.each { |k, v| attrs[k] = v.to_a if v.is_a?(Set) }
          "#{group.pretty_inspect.rstrip} => #{attrs.pretty_inspect.rstrip}"
        end
        lines.join("\n  ")
      end unless warnings.empty?

      result.values.each(&:freeze).freeze
    end
  end
end
