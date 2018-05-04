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

    require_relative 'lib/aws_products_data_collector'
    require_relative 'lib/aws_instance_types_parser'
    require_relative 'lib/simple_logging'

    data_dir = ManageIQ::Providers::Amazon::Engine.root.join('db/fixtures')
    data_dir.mkpath

    out_file = data_dir.join('aws_instance_types.yml')
    out_file_old = data_dir.join('aws_instance_types_old.yml')

    # 'Dedicated Host', # TODO: do we need bare metal types here? e.g. "m5", "p3", etc.
    products = AwsProductsDataCollector.new(
      'AmazonEC2', 'Compute Instance', AwsInstanceTypesParser::REQUIRED_ATTRIBUTES,
      'instanceType', 'currentGeneration').products_list

    instances = AwsInstanceTypesParser.new(products).instances_list

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
