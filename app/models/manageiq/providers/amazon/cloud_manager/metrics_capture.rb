# frozen_string_literal: true

class ManageIQ::Providers::Amazon::CloudManager::MetricsCapture < ManageIQ::Providers::BaseManager::MetricsCapture
  INTERVALS = [5.minutes.freeze, 1.minute.freeze].freeze

  VIM_STYLE_COUNTERS = [
    {
      :counter_key  => 'cpu_usage_rate_average',
      :unit_key     => 'percent',
      :precision    => 1,
      :metric_names => %w[
        CPUUtilization
      ].freeze,
      :calculation  => ->(stat, _) { stat },
    },
    {
      :counter_key  => 'mem_usage_absolute_average',
      :unit_key     => 'percent',
      :precision    => 1,
      :metric_names => %w[
        MemoryUtilization
      ].freeze,
      :calculation  => ->(stat, _) { stat },
    },
    {
      :counter_key  => 'mem_swapped_absolute_average',
      :unit_key     => 'percent',
      :precision    => 1,
      :metric_names => %w[
        SwapUtilization
      ].freeze,
      :calculation  => ->(stat, _) { stat },
    },
    {
      :counter_key  => 'disk_usage_rate_average',
      :unit_key     => 'kilobytespersecond',
      :precision    => 2,
      :metric_names => %w[
        DiskReadBytes
        DiskWriteBytes
      ].freeze,
      :calculation  => ->(*stats, interval) { stats.compact.sum / 1024.0 / interval },
    },
    {
      :counter_key  => 'net_usage_rate_average',
      :unit_key     => 'kilobytespersecond',
      :precision    => 2,
      :metric_names => %w[
        NetworkIn
        NetworkOut
      ].freeze,
      :calculation  => ->(*stats, interval) { stats.compact.sum / 1024.0 / interval },
    },
  ].each_with_object({}) do |counter, memo|
    memo[counter.fetch(:counter_key)] = counter.merge!({
      :instance              => '',
      :capture_interval      => '20',
      :capture_interval_name => 'realtime',
      :rollup                => 'average',
    }).freeze
  end.freeze

  COUNTER_NAMES = VIM_STYLE_COUNTERS.values.flat_map { |i| i[:metric_names] }.uniq.compact.freeze

  def perf_collect_metrics(interval_name, start_time = nil, end_time = nil)
    raise 'No EMS defined' unless ems

    log_header = "[#{interval_name}] for: [#{target.class.name}], [#{target.id}], [#{target.name}]"

    end_time   ||= Time.now
    end_time     = end_time.utc
    start_time ||= end_time - 4.hours # 4 hours for symmetry with VIM
    start_time   = start_time.utc

    begin
      # This is just for consistency, to produce a :connect benchmark
      Benchmark.realtime_block(:connect) {}
      target.ext_management_system.with_provider_connection(:service => :CloudWatch) do |cloud_watch|
        perf_capture_data_amazon(cloud_watch, start_time, end_time)
      end
    rescue Exception => err
      _log.error("#{log_header} Unhandled exception during perf data collection: [#{err}], class: [#{err.class}]")
      _log.error("#{log_header}   Timings at time of error: #{Benchmark.current_realtime.inspect}")
      _log.log_backtrace(err)
      raise
    end
  end

  private

  def perf_capture_data_amazon(cloud_watch, start_time, end_time)
    # Since we are unable to determine if the first datapoint we get is a
    #   1-minute (detailed) or 5-minute (basic) interval, we will need to throw
    #   it away.  So, we ask for at least one datapoint earlier than what we
    #   need.
    start_time -= 5.minutes

    counters                = get_counters(cloud_watch)
    metrics_by_counter_name = metrics_by_counter_name(cloud_watch, counters, start_time, end_time)
    counter_values_by_ts    = counter_values_by_timestamp(metrics_by_counter_name)

    counters_by_id              = {target.ems_ref => VIM_STYLE_COUNTERS}
    counter_values_by_id_and_ts = {target.ems_ref => counter_values_by_ts}
    return counters_by_id, counter_values_by_id_and_ts
  end

  def counter_values_by_timestamp(metrics_by_counter_name)
    counter_values_by_ts = {}
    COUNTER_INFO.each do |i|
      timestamps = i[:amazon_counters].collect do |c|
        metrics_by_counter_name[c].keys unless metrics_by_counter_name[c].nil?
      end.flatten.uniq.compact.sort

      # If we are unable to determine if a datapoint is a 1-minute (detailed)
      #   or 5-minute (basic) interval, we will throw it away.  This includes
      #   the very first interval.
      timestamps.each_cons(2) do |last_ts, ts|
        interval = ts - last_ts
        next unless interval.in?(INTERVALS)

        metrics = i[:amazon_counters].collect { |c| metrics_by_counter_name.fetch_path(c, ts) }
        value   = i[:calculation].call(*metrics, interval)

        # For (temporary) symmetry with VIM API we create 20-second intervals.
        (last_ts + 20.seconds..ts).step_value(20.seconds).each do |inner_ts|
          counter_values_by_ts.store_path(inner_ts.iso8601, i[:vim_style_counter_key], value)
        end
      end
    end
    counter_values_by_ts
  end

  def metrics_by_counter_name(cloud_watch, counters, start_time, end_time)
    metrics_by_counter_name = {}
    counters.each do |c|
      metrics = metrics_by_counter_name[c.metric_name] = {}

      # Only ask for 1 day at a time, since there is a limitation on the number
      #   of datapoints you are allowed to ask for from Amazon Cloudwatch.
      #   http://docs.amazonwebservices.com/AmazonCloudWatch/latest/APIReference/API_GetMetricStatistics.html
      (start_time..end_time).step_value(1.day).each_cons(2) do |st, et|
        statistics, = Benchmark.realtime_block(:capture_counter_values) do
          options = {:start_time => st, :end_time => et, :statistics => ["Average"], :period => 60}
          cloud_watch.client.get_metric_statistics(c.to_hash.merge(options)).datapoints
        end

        statistics.each { |s| metrics[s.timestamp.utc] = s.average }
      end
    end
    metrics_by_counter_name
  end

  def get_counters(cloud_watch)
    counters, = Benchmark.realtime_block(:capture_counters) do
      filter = [{:name => "InstanceId", :value => target.ems_ref}]
      cloud_watch.client.list_metrics(:dimensions => filter).metrics.select { |m| m.metric_name.in?(COUNTER_NAMES) }
    end
    counters
  end

  ## attribute shortcuts

  def ems
    return @ems if defined? @ems
    @ems = target.ext_management_system
  end

  delegate :ems_ref, :to => :target, :allow_nil => true
  delegate :name,    :to => :target, :allow_nil => true, :prefix => true

  alias resource_name target_name

  def resource_group
    return @resource_group if defined? @resource_group
    @resource_group = target.resource_group.name
  end

  def resource_description
    return @resource_description if defined? @resource_description
    @resource_description = "#{resource_name}/#{resource_group}"
  end

  def provider_region
    return @provider_region if defined? @provider_region
    @provider_region = ems.provider_region
  end

  def storage_accounts(storage_account_service)
    @storage_accounts ||= storage_account_service.list_all
  end
end
