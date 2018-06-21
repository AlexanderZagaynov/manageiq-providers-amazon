# frozen_string_literal: true

require 'active_support/core_ext/string/inflections'
require 'active_support/core_ext/array/access'
require_relative 'memoizable'

class AwsInstanceDataParser
  include Memoizable

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

  # https://github.com/ManageIQ/manageiq-providers-amazon/
  #   blob/933a3d08e0adb012c7cbefbaeaa262a81c855fe1/
  #   lib/tasks_private/instance_types.rake#L49
  CLUSTERABLE_TYPES = %w(m4 c3 c4 cr1 r4 x1 hs1 i2 g2 p2 d2).freeze

  ParsedName = Struct.new(*%i(base_type size_factor size_name))
  ParsedStorage = Struct.new(*%i(volumes size type))

  private_constant *constants(false).without(:REQUIRED_ATTRIBUTES)

  attr_reader :product_data

  def initialize(product_data)
    @parsed = false
    @product_data = product_data
    @unknown_values = {}
  end

  memoized def result
    [instance_data, unknown_values]
  end

  def instance_data
    parse! unless @parsed
    @instance_data
  end

  def unknown_values
    parse! unless @parsed
    @unknown_values
  end

  ### individual attributes

  ## general

  memoized def current_generation?
    product_data['currentGeneration'] == 'Yes'
  end

  memoized def deprecated?
    !current_generation?
  end

  memoized def instance_type
    product_data['instanceType']
  end

  memoized def instance_family
    product_data['instanceFamily']
  end

  memoized def base_type
    parsed_name.base_type
  end

  memoized def description
    description = [base_type.upcase]
    description << instance_family.titleize unless POPULAR_TYPES.include?(base_type)
    description << (size_name == 'xlarge' ? "#{size_factor}XL" : size_name.capitalize)
    description.join(' ')
  end

  ## virtualization

  memoized def virtualization_type
    VIRT_TYPES[base_type]
  end

  memoized def size_factor
    parsed_name.size_factor
  end

  memoized def size_name
    parsed_name.size_name
  end

  memoized def vcpus
    product_data['vcpu'].to_i
  end

  ## cpu

  memoized def physical_processor
    product_data['physicalProcessor']
  end

  memoized def cpu_clock_speed
    product_data['clockSpeed']
  end

  memoized def cpu_arches
    CPU_ARCHES.fetch(product_data['processorArchitecture']) do |cpu_arch|
      save_unknown(cpu_arch)
    end
  end

  memoized def processor_features
    product_data['processorFeatures']
  end

  memoized def intel_avx?
    product_data['intelAvxAvailable'] == 'Yes' || !(processor_features !~ INTEL_AVX_REGEXP)
  end

  memoized def intel_avx2?
    product_data['intelAvx2Available'] == 'Yes' || !(processor_features !~ INTEL_AVX2_REGEXP)
  end

  memoized def intel_turbo?
    product_data['intelTurboAvailable'] == 'Yes' || !(processor_features !~ INTEL_TURBO_REGEXP)
  end

  memoized def intel_aes_ni?
    !deprecated?
  end

  ## memory

  memoized def memory
    memory = product_data['memory']
    (MEMORY_REGEXP.match(memory)&.captures&.first || save_unknown(memory)).to_f
  end

  ## storage

  memoized def storage
    product_data['storage']
  end

  memoized def ebs_only?
    storage == 'EBS only'
  end

  memoized def ebs_optimized?
    product_data['ebsOptimized'] == 'Yes'
  end

  memoized def storage_volumes
    parsed_storage.volumes
  end

  memoized def storage_size
    parsed_storage.size
  end

  memoized def storage_type
    parsed_storage.type
  end

  ## network

  memoized def network_performance
    net_perf = product_data['networkPerformance']
    net_perf =~ NETWORK_REGEXP ? :very_high : net_perf.downcase.gsub(/\s/, '_').to_sym
  end

  memoized def enhanced_networking?
    product_data['enhancedNetworkingSupported'] == 'Yes'
  end

  memoized def clusterable_networking?
    CLUSTERABLE_TYPES.include?(base_type)
  end

  memoized def vpc_only?
    VPC_ONLY_TYPES.include?(base_type)
  end

  private

  def parse!
    @instance_data = {
      :deprecated              => deprecated?,
      :name                    => instance_type,
      :family                  => instance_family,
      :description             => description,
      :memory                  => memory.gigabytes,
      :memory_gb               => memory,
      :vcpu                    => vcpus,
      :ebs_only                => ebs_only?,
      :instance_store_size     => storage_size.gigabyte,
      :instance_store_size_gb  => storage_size,
      :instance_store_volumes  => storage_volumes,
      :instance_store_type     => storage_type,
      :architecture            => cpu_arches,
      :virtualization_type     => virtualization_type,
      :network_performance     => network_performance,
      :physical_processor      => physical_processor,
      :processor_clock_speed   => cpu_clock_speed,
      :intel_aes_ni            => intel_aes_ni?           || nil,
      :intel_avx               => intel_avx?              || nil,
      :intel_avx2              => intel_avx2?             || nil,
      :intel_turbo             => intel_turbo?            || nil,
      :ebs_optimized_available => ebs_optimized?          || nil,
      :enhanced_networking     => enhanced_networking?    || nil,
      :cluster_networking      => clusterable_networking? || nil,
      :vpc_only                => vpc_only?               || nil,
    }.freeze
    @unknown_values.freeze
    @parsed = true
  end

  def save_unknown(value, attribute_name = nil, nils: nil)
    attribute_name ||= caller_locations(1..1).first.label # use a bit of magic
    (@unknown_values[attribute_name.to_sym] ||= Set.new) << value
    nils ? Array.new(nils, nil) : nil
  end

  ### compound attributes

  memoized def parsed_name
    ParsedName.new(*(TYPE_REGEXP.match(instance_type)&.captures ||
      save_unknown(instance_type, :instance_type, :nils => 3)
    )).freeze
  end

  memoized def parsed_storage
    volumes, size, type =
      if ebs_only?
        Array.new(3, nil)
      else
        STORAGE_REGEXP.match(storage)&.captures ||
          save_unknown(storage, :storage, :nils => 3)
      end
    volumes = volumes.to_i
    size = size&.gsub(/\D/, '').to_f * volumes
    ParsedStorage.new(volumes, size, type)
  end
end
