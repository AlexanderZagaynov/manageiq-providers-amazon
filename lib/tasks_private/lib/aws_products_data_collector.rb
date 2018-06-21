# frozen_string_literal: true

# https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/using-ppslong.html

require 'uri'
require 'json'
require 'digest'
require 'net/http'
require 'active_support/cache/file_store'
require 'active_support/core_ext/hash/slice'
require 'active_support/core_ext/array/wrap'
require_relative 'memoizable'

class AwsProductsDataCollector
  include Memoizable

  OFFERS_HOSTNAME = 'https://pricing.us-east-1.amazonaws.com'

  cattr_accessor :cache, :instance_writer => false do
    ActiveSupport::Cache::FileStore.new(
      Rails.root.join('tmp/aws_cache/products_data_collector'))
  end

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

    @parsed = false
  end

  memoized def result
    [products_data, deviations]
  end

  def products_data
    parse! unless @parsed
    @products_data
  end

  def deviations
    parse! unless @parsed
    @warnings
  end

  private

  def parse!
    result, warnings = cache.fetch("ec2_products_summary.#{offer_versions_cache_key}") do
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

    @warnings = warnings
    @products_data = result.values.each(&:freeze).freeze
  end

  memoized def offers_index_uri
    URI("#{OFFERS_HOSTNAME}/offers/v1.0/aws/#{service_name}/index.json")
  end

  # offers_index['currentVersion'] # TODO: product['currentGeneration']
  memoized def offers_index
    cache.fetch("offers_index_#{service_name}", :expires_in => 1.week) do
      JSON.parse(Net::HTTP.get_response(offers_index_uri).body)
    end
  end

  memoized def offer_versions
    offers_index['versions'].sort.to_h.freeze
  end

  memoized def offer_versions_cache_key
    offer_versions.each_key.with_object(Digest::SHA1.new) do |version, digest|
      digest << version
    end.hexdigest
  end

  memoized def offers_version_uri(version_data)
    URI("#{OFFERS_HOSTNAME}#{version_data['offerVersionUrl']}")
  end

  memoized def offers_data
    cache.fetch("ec2_offers_summary.#{offer_versions_cache_key}") do
      offer_versions.map do |version_name, version_data|
        cache.fetch("ec2_offers.#{version_name}") do
          offers_uri = offers_version_uri(version_data)
          json_text = Net::HTTP.get_response(offers_uri).body
          JSON.parse(json_text)['products'].values
        end
      end.reduce(&:+)
    end
  end
end
