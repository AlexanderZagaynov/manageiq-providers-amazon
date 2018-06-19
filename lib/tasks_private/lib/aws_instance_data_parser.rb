# frozen_string_literal: true

require 'active_support/core_ext/string/inflections'
require_relative 'simple_logging'

class AwsInstanceDataParser
  REQUIRED_ATTRIBUTES = %w(
    clockSpeed
    currentGeneration
    dedicatedEbsThroughput
    ebsOptimized
    enhancedNetworkingSupported
    instanceFamily
    instanceType
    intelAvx2Available
    intelAvxAvailable
    intelTurboAvailable
    memory
    networkPerformance
    physicalProcessor
    processorArchitecture
    processorFeatures
    storage
    vcpu
  ).freeze

  TYPE_REGEXP    = /^(?:(.*)\.)?(\d+)?(.*)/
  MEMORY_REGEXP  = /^\s*(\d*\.?\d*)\s+GiB\s*$/i
  STORAGE_REGEXP = /^(?:(\d+)\s+x\s+)((?:\d+[.,])?\d+)(?:\s+(.+))?$/
  NETWORK_REGEXP = /^\d+\sGigabit$/i

  INTEL_AVX_REGEXP   = /\bIntel AVX\b/
  INTEL_AVX2_REGEXP  = /\bIntel AVX2\b/
  INTEL_TURBO_REGEXP = /\bIntel Turbo\b/

  CPU_ARCHES = {
    '32-bit or 64-bit' => %i(i386 x86_64).freeze,
    '64-bit'           => %i(x86_64).freeze,
  }.freeze

  # https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/virtualization_types.html
  VIRT_TYPES = Hash.new(%i(hvm).freeze).tap do |virt_types|
    { %w(t1 m1 m2 c1)   => %i(paravirtual).freeze,
      %w(m3 c3 hs1 hi1) => %i(paravirtual hvm).freeze,
    }.each do |type_names, types_set|
      type_names.each { |type_name| virt_types[type_name] = types_set }
    end
  end.freeze

  # for :description
  POPULAR_TYPES = %w(t1 t2).freeze

  # https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-vpc.html#vpc-only-instance-types
  VPC_ONLY_TYPES = %w(m4 m5 t2 c4 c5 r4 x1 h1 i3 f1 g3 p2 p3).freeze

  # https://github.com/ManageIQ/manageiq-providers-amazon/blob/933a3d08e0adb012c7cbefbaeaa262a81c855fe1/lib/tasks_private/instance_types.rake#L49
  CLUSTERABLE_TYPES = %w(m4 c3 c4 cr1 r4 x1 hs1 i2 g2 p2 d2).freeze

  attr_reader :product_data

  def initialize(product_data)
    @product_data = product_data
    @coercion_errors = {}
  end

  def instance_data
    @instance_data ||= begin
      instance_type = product_data['instanceType']
      type_name, multiplier, size_name = TYPE_REGEXP.match(instance_type)&.captures

      deprecated = product_data['currentGeneration'] != 'Yes'

      description = [type_name.upcase]
      description << product_data['instanceFamily'].titleize unless POPULAR_TYPES.include?(type_name)
      description << (size_name == 'xlarge' ? "#{multiplier}XL" : size_name.capitalize)
      description = description.join(' ')

      memory = product_data['memory']
      memory = MEMORY_REGEXP.match(memory) { |m| m.captures.first }.tap do |m|
        (coercion_errors[:memory] ||= {})[instance_type] = memory unless m
      end.to_f

      storage = product_data['storage']
      ebs_only = storage == 'EBS only'
      storage_volumes, storage_size, storage_type = ebs_only ? nil :
      STORAGE_REGEXP.match(storage)&.captures || begin
        (coercion_errors[:storage] ||= {})[instance_type] = storage
        nil
      end
      storage_volumes = storage_volumes.to_i
      storage_size = storage_size&.gsub(/\D/, '').to_f * storage_volumes

      cpu_arch = CPU_ARCHES.fetch(product_data['processorArchitecture']) do |cpu_arch|
        (coercion_errors[:cpu_arch] ||= {})[instance_type] = cpu_arch
        nil
      end

      net_perf = product_data['networkPerformance']
      net_perf = net_perf =~ NETWORK_REGEXP ? :very_high : net_perf.downcase.gsub(/\s/, '_').to_sym

      processor_features = product_data['processorFeatures']
      intel_avx    = product_data['intelAvxAvailable']   == 'Yes' || processor_features =~ INTEL_AVX_REGEXP
      intel_avx2   = product_data['intelAvx2Available']  == 'Yes' || processor_features =~ INTEL_AVX2_REGEXP
      intel_turbo  = product_data['intelTurboAvailable'] == 'Yes' || processor_features =~ INTEL_TURBO_REGEXP
      intel_aes_ni = !deprecated

      {
        :deprecated              => deprecated,
        :name                    => instance_type,
        :family                  => product_data['instanceFamily'],
        :description             => description,
        :memory                  => memory.gigabytes,
        :memory_gb               => memory,
        :vcpu                    => product_data['vcpu'].to_i,
        :ebs_only                => ebs_only,
        :instance_store_size     => storage_size.gigabyte,
        :instance_store_size_gb  => storage_size,
        :instance_store_volumes  => storage_volumes,
        :instance_store_type     => storage_type, # TODO: needed?
        :architecture            => cpu_arch,
        :virtualization_type     => VIRT_TYPES[type_name],
        :network_performance     => net_perf,
        :physical_processor      => product_data['physicalProcessor'],
        :processor_clock_speed   => product_data['clockSpeed'],
        :intel_aes_ni            => intel_aes_ni ? true : nil,
        :intel_avx               => intel_avx    ? true : nil,
        :intel_avx2              => intel_avx2   ? true : nil,
        :intel_turbo             => intel_turbo  ? true : nil,
        :ebs_optimized_available => product_data['ebsOptimized']                == 'Yes' || nil,
        :enhanced_networking     => product_data['enhancedNetworkingSupported'] == 'Yes' || nil,
        :cluster_networking      => CLUSTERABLE_TYPES.include?(type_name) || nil,
        :vpc_only                => VPC_ONLY_TYPES.include?(type_name)    || nil,
      }.freeze
    end
  end

  private

  attr_reader :coercion_errors
end
