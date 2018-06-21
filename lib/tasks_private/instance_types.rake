# frozen_string_literal: true

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
    require 'logger'

    require_relative 'lib/aws_api_info'
    require_relative 'lib/aws_products_data_collector'
    require_relative 'lib/aws_instance_data_parser'

    # require 'active_support/core_ext/module/delegation'
    # delegate *%i(info debug warn error fatal), :to => :logger

    # weird cache logging issue workaround
    unless Rails.initialized?
      require 'active_support/i18n'
      I18n.backend = I18n.backend.backend
    end

    logger = Logger.new(STDOUT)
    GithubFile.logger = logger
    AwsProductsDataCollector.cache.logger = logger

    data_dir = ManageIQ::Providers::Amazon::Engine.root.join('db/fixtures')
    data_dir.mkpath

    out_file = data_dir.join('aws_instance_types.yml')
    # out_file_old = data_dir.join('aws_instance_types_old.yml')

    types_list = AwsApiInfo.new('EC2').api_data['shapes']['InstanceType']['enum'].freeze

    products_data, collecting_warnings = AwsProductsDataCollector.new(
      :service_name => 'AmazonEC2',
      :product_families => 'Compute Instance', # 'Dedicated Host' == bare metal: "m5", "p3", etc.
      :product_attributes => AwsInstanceDataParser::REQUIRED_ATTRIBUTES,
      :folding_attributes => 'instanceType',
      :mutable_attributes => 'currentGeneration',
    ).result

    parsing_warnings = {}

    types_data = products_data.map do |product_data|
      instance_data, warnings = AwsInstanceDataParser.new(product_data).result
      parsing_warnings.merge!(warnings) { |_, old, new| old + new }
      [product_data['instanceType'], instance_data]
    end.sort_by do |instance_type, _|
      types_list.index(instance_type) || instance_type
    end.to_h.freeze

    unknown_types = types_data.keys - types_list

    ap collecting_warnings
    ap parsing_warnings
    ap unknown_types

    # warn do
    #   warnings..sort
    #   lines = []
    #   lines << 'Attention! Contradictory products data:'
    #   lines += warnings.map do |group, attrs|
    #     attrs.each { |k, v| attrs[k] = v.to_a if v.is_a?(Set) }
    #     "#{group.pretty_inspect.rstrip} => #{attrs.pretty_inspect.rstrip}"
    #   end
    #   lines.join("\n  ")
    # end unless parser.unknown_values.empty?

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

    out_file.write(types_data.to_yaml.each_line.map(&:rstrip).join("\n") << "\n")
  end
end
