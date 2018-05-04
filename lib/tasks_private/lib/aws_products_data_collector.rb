# frozen_string_literal: true

require 'uri'
require 'json'
require 'digest'
require 'memoist'
require 'net/http'
require 'active_support/cache/file_store'
require 'active_support/core_ext/hash/slice'
require 'active_support/core_ext/array/wrap'
require_relative 'simple_logging'

class AwsProductsDataCollector
  extend Memoist

  TMP_DIR = Rails.root.join('tmp/aws_cache')
  OFFERS_HOSTNAME = 'https://pricing.us-east-1.amazonaws.com'

  attr_reader *%i(
    service_name
    product_families
    product_attributes
    group_attribute
    group_attributes
    mutable_attributes
  )

  def initialize(service_name,
                 product_families,
                 product_attributes,
                 group_attributes,
                 mutable_attributes = nil)

    @service_name       = service_name
    @product_families   = Array.wrap(product_families).dup.freeze
    @product_attributes = Array.wrap(product_attributes).dup.freeze
    @mutable_attributes = Array.wrap(mutable_attributes).dup.freeze

    if group_attributes.is_a?(Array)
      @group_attributes = group_attributes.dup.freeze
    else
      @group_attribute = group_attributes
    end
  end

  def offers_index_uri
    URI("#{OFFERS_HOSTNAME}/offers/v1.0/aws/#{service_name}/index.json")
  end

  def offers_index
    # JSON.parse(Net::HTTP.get_response(offers_index_uri).body)
    JSON.parse File.read('/home/azagayno/Downloads/aws/index.json')
  end
  # offers_index['currentVersion'] # TODO: product['currentGeneration']

  def offer_versions
    offers_index['versions'].sort.to_h
  end

  def offer_versions_cache_key
    offer_versions.keys.each_with_object(Digest::SHA1.new) do |version, digest|
      digest << version
    end.hexdigest
  end

  def offers_data

    summary_file = TMP_DIR.join("ec2_offers_summary.#{offer_versions_cache_key}.yml")
    if summary_file.file?
      info "Using cached collected data: #{summary_file}"
      memo = YAML.load_file(summary_file)
    else
      memo = []
      offer_versions.each do |version_name, version_data|
        tmp_file = TMP_DIR.join("ec2_offers.#{version_name}.json")
        if tmp_file.file?
          info "Using cached data: #{tmp_file}"
          json_text = tmp_file.read
        else
          offers_uri = URI("#{OFFERS_HOSTNAME}#{version_data['offerVersionUrl']}")
          info "Getting data from #{offers_uri}"
          json_text = Net::HTTP.get_response(offers_uri).body
          tmp_file.write(json_text)
        end
        memo += JSON.parse(json_text)['products'].values
      end
      summary_file.write(memo.to_yaml)
    end
    memo
  end

  def products_list
    result, warnings = offers_data.each_with_object([{}, {}]) do |product, (memo, deviations)|
      next unless product_families.include?(product['productFamily'])

      item_attrs = product['attributes'].slice(*product_attributes)
      if group_attribute
        items_group = item_attrs.fetch(group_attribute)
      else
        items_group = item_attrs.fetch_values(*group_attributes)
      end

      group_data = memo[items_group] ||= {}
      group_data.merge!(item_attrs) do |key, old_value, new_value|
        unless old_value.casecmp(new_value).zero? || mutable_attributes.include?(key)
          values = (deviations[items_group] ||= {})[key] ||= Set[old_value]
          values << new_value
        end
        new_value # versions are sorted, taking the freshest value
      end
    end

    unless warnings.empty?
      warnings.each_value do |warning_data|
        warning_data.each { |k, v| warning_data[k] = v.to_a if v.is_a?(Set) }
      end
      warn { "Attention! Contradictory products data:\n#{JSON.pretty_generate(warnings)}" }
    end

    result
  end

  memoize *%i(
    offers_index_uri
    offers_index
    offer_versions
    offer_versions_cache_key
    offers_data
    products_list
  )
end
