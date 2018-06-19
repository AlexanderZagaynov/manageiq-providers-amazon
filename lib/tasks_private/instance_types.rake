# frozen_string_literal: true

# https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/using-ppslong.html#download-the-offer-index

require 'pry-byebug'
require 'awesome_print'

namespace 'aws:extract' do
  desc 'Get / renew instance types and details list from AWS Price List Bulk API'
  task :instance_types do
    require 'uri'
    require 'set'
    require 'json'
    require 'yaml'
    require 'net/http'

    require_relative 'lib/aws_api_info'
    require_relative 'lib/aws_products_data_collector'
    require_relative 'lib/aws_instance_data_parser'
    require_relative 'lib/simple_logging'

    data_dir = ManageIQ::Providers::Amazon::Engine.root.join('db/fixtures')
    data_dir.mkpath

    out_file = data_dir.join('aws_instance_types.yml')
    out_file_old = data_dir.join('aws_instance_types_old.yml')

    instance_types = AwsApiInfo.new('EC2').api_data['shapes']['InstanceType']['enum'].freeze

    instances = AwsProductsDataCollector.new(
      :service_name => 'AmazonEC2',
      :product_families => 'Compute Instance', # 'Dedicated Host' == bare metal: "m5", "p3", etc.
      :product_attributes => AwsInstanceDataParser::REQUIRED_ATTRIBUTES,
      :folding_attributes => 'instanceType',
      :mutable_attributes => 'currentGeneration',
    ).products_data.sort_by do |product_data|
      instance_type = product_data['instanceType']
      instance_types.index(instance_type) || instance_type
    end.map do |product_data|
      # (list.keys - types_order).tap do |unknown_types|
      #   coercion_errors[:types_order] = unknown_types unless unknown_types.empty?
      # end
      instance_data = AwsInstanceDataParser.new(product_data).instance_data
      [product_data['instanceType'], instance_data]
    end.to_h.freeze

    # unless coercion_errors.empty?
    #   error { "Attention! Check those coercion errors:\n#{JSON.pretty_generate(coercion_errors)}" }
    #   raise 'Inconvertible instance types data'
    # end

    # prevent yaml anchors/aliases
    module Psych::Visitors::YAMLTree::Patches
      def accept(target)
        old_st = @st
        @st = self.class::Registrar.new if @st.key?(target)
        res = super
        @st = old_st
        res
      end
    end
    Psych::Visitors::YAMLTree.prepend(Psych::Visitors::YAMLTree::Patches)

    out_file.write(instances.to_yaml)
  end
end

# except_attributes = %w(
#   location
#   usagetype
#   operation
#   tenancy
#   capacitystatus
#   licenseModel
#   preInstalledSw
#   operatingSystem
#   ebsOptimized
# ).freeze
## !!! max(ebsOptimized)
