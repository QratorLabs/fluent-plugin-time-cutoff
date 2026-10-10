# frozen_string_literal: true

require 'fluent/plugin/filter'
require 'json'
require 'socket'
require 'time'

module Fluent
  module Plugin
    # A filter plugin that allows Fluentd to modify or drop messages that are
    # newer or older than a set threshold. By default this filter will not
    # modify or drop any messages, but it will log all messages that are 24
    # hours older or newer than current time.
    class TimeCutoffFilter < Fluent::Plugin::Filter
      # Available actions for messages.
      CUTOFF_ACTIONS = [
        # Pass record as is:
        :pass,
        # Replace time with "now" and pass:
        :replace_timestamp,
        # Drop record as invalid:
        :drop
      ].freeze

      # Available time formats for :replace_timestamp action.
      TIME_FORMATS = [
        # UNIX time (integer)
        :epoch,
        # UNIX time (float)
        :epoch_float,
        # ISO 8601 datetime (string)
        :iso8601
      ].freeze

      # Available actions for records with an unparseable time.
      BAD_TIME_ACTIONS = [
        # Replace time with "now" and pass:
        :replace_timestamp,
        # Drop record as invalid:
        :drop
      ].freeze

      # Available actions for records that already have the key the original
      # time should be put into (for :replace_timestamp action).
      TIME_KEY_CONFLICT_ACTIONS = [
        # Keep the existing value:
        :skip,
        # Keep the existing value and log a warning:
        :warn,
        # Replace the existing value:
        :overwrite
      ].freeze

      # Available log modes for caught records.
      LOG_MODES = [
        # Do not log:
        :none,
        # Log tag, time and age (or the raw unparseable time) only:
        :metadata,
        # Log the whole record:
        :full,
        # Aliases for :none and :full, kept for compatibility with the
        # boolean *_log options of earlier versions:
        :false,
        :no,
        :true,
        :yes
      ].freeze

      # Log modes the boolean aliases stand for.
      LOG_MODE_ALIASES = { false: :none, no: :none, true: :full, yes: :full }.freeze

      # Name and label names of the Prometheus counter for caught records.
      METRIC_NAME = :fluentd_time_cutoff_records_total
      METRIC_LABELS = %i[plugin_id worker_id hostname tag reason action].freeze

      # strftime() format string for :iso8601 time format.
      TIME_ISO8601 = '%FT%T%:z'

      # Matches a "relaxed" ISO 8601 datetime string, which uses a space
      # instead of "T" between the date and the time and/or has a space
      # before the timezone (e.g. Ruby's Time#to_s: "2026-10-10 03:57:04 +0300"
      # or "2026-10-10 00:57:04 UTC"), so that it can be rebuilt as a strict one.
      ISO8601_RELAXED = /
        \A
        (?<date>\d{4}-\d{2}-\d{2})
        [T\ ]
        (?<time>\d{2}:\d{2}:\d{2}(?:\.\d+)?)
        (?:\ ?(?<zone>Z|UTC|[+-]\d{2}(?::?\d{2})?))?
        \z
      /x.freeze

      Fluent::Plugin.register_filter('time_cutoff', self)

      desc 'Records older than this amount of time are deemed "old". Defaults to 24 hours.'
      config_param :old_cutoff, :time, default: 86_400 # 24 hours
      desc 'The action that will be performed to all "old" messages. Defaults to passthrough.'
      config_param :old_action, :enum, list: CUTOFF_ACTIONS, default: :pass
      desc 'Log the "old" messages to Fluentd\'s own log: none (false/no), metadata or full (true/yes). Defaults to "full".'
      config_param :old_log, :enum, list: LOG_MODES, default: :full
      desc 'Records newer than this amount of time are deemed "new". Defaults to 24 hours.'
      config_param :new_cutoff, :time, default: 86_400 # 24 hours
      desc 'The action that will be performed to all "new" messages. Defaults to passthrough.'
      config_param :new_action, :enum, list: CUTOFF_ACTIONS, default: :pass
      desc 'Log the "new" messages to Fluentd\'s own log: none (false/no), metadata or full (true/yes). Defaults to "full".'
      config_param :new_log, :enum, list: LOG_MODES, default: :full
      desc 'The key that will hold the original time (for :replace_timestamp action). Defaults to "source_time".'
      config_param :source_time_key, :string, default: 'source_time'
      desc 'Time format for the original timestamp field. Defaults to ISO8601-formatted string.'
      config_param :source_time_format, :enum, list: TIME_FORMATS, default: :iso8601
      desc 'The action that will be performed to all messages with an unparseable time. Defaults to replacing it with current time.'
      config_param :bad_time_action, :enum, list: BAD_TIME_ACTIONS, default: :replace_timestamp
      desc 'Log the messages with an unparseable time to Fluentd\'s own log: none (false/no), metadata or full (true/yes). Defaults to "full".'
      config_param :bad_time_log, :enum, list: LOG_MODES, default: :full
      desc 'The key that will hold the original unparseable time (for :replace_timestamp action). Defaults to "source_time_raw".'
      config_param :bad_time_key, :string, default: 'source_time_raw'
      desc 'The action that will be performed when the record already has source_time_key or bad_time_key. Defaults to keeping the existing value.'
      config_param :time_key_conflict, :enum, list: TIME_KEY_CONFLICT_ACTIONS, default: :skip
      desc 'Count caught records in a Prometheus counter (needs the prometheus-client gem). Defaults to "false".'
      config_param :metrics, :bool, default: false

      def configure(conf)
        super

        %i[old_cutoff new_cutoff].each do |param|
          # NOTE: Fluentd's :time type drops the sign of values with a unit
          # (e.g. "-1h" is parsed as 3600), so the raw value is checked too.
          raw = conf[param.to_s].to_s.strip
          next unless raw.start_with?('-') || instance_variable_get("@#{param}").negative?

          raise Fluent::ConfigError, "#{param} must not be negative, got \"#{raw}\""
        end
        %i[source_time_key bad_time_key].each do |param|
          raise Fluent::ConfigError, "#{param} must not be empty" if instance_variable_get("@#{param}").empty?
        end
        if @source_time_key == @bad_time_key
          raise Fluent::ConfigError, "source_time_key and bad_time_key must differ, both are \"#{@source_time_key}\""
        end

        %i[old_log new_log bad_time_log].each do |param|
          mode = instance_variable_get("@#{param}")
          instance_variable_set("@#{param}", LOG_MODE_ALIASES.fetch(mode, mode))
        end

        setup_metrics
      end

      def filter_with_time(tag, time, record)
        ## Safeguard against rogue integer/float/string time. This has to happen
        ## before classification, so that the age check uses the parsed value.
        unless time.is_a?(Fluent::EventTime)
          normalized = normalize_time(time)
          return process_bad_time_record(tag, time, record) if normalized.nil?

          time = normalized
        end

        event_time = time.to_i
        now = current_time

        if event_time < now - @old_cutoff
          # Too old
          process_old_record(tag, time, record)
        elsif event_time > now + @new_cutoff
          # Too new
          process_new_record(tag, time, record)
        else
          # OK
          [time, record]
        end
      end

      private

      # Set up the Prometheus counter for caught records, if enabled. The
      # counter is shared by all time_cutoff filters in the process.
      def setup_metrics
        return unless @metrics

        unless load_prometheus_client
          log.warn 'Metrics are enabled, but the prometheus-client gem is not installed, so caught records will not be counted.'
          return
        end

        registry = prometheus_registry
        @records_counter = registry.get(METRIC_NAME) || registry.counter(
          METRIC_NAME,
          docstring: 'Number of records caught by the time_cutoff filter.',
          labels: METRIC_LABELS
        )
        @metric_labels = { plugin_id: plugin_id, worker_id: worker_id.to_s, hostname: Socket.gethostname }
      end

      # Load the prometheus-client gem, which is an optional dependency.
      # @return [Boolean] whether the gem could be loaded
      def load_prometheus_client
        require 'prometheus/client'
        true
      rescue LoadError
        false
      end

      # The Prometheus registry to register the counter in. This is the one
      # fluent-plugin-prometheus serves on its /metrics endpoints.
      def prometheus_registry
        ::Prometheus::Client.registry
      end

      # ID of the Fluentd worker this plugin runs in.
      # NOTE: Plugin::Base#fluentd_worker_id isn't available in the oldest
      # Fluentd releases declared in the gemspec, so fall back to the env var
      # it reads.
      # @return [Integer] worker ID
      def worker_id
        return fluentd_worker_id if respond_to?(:fluentd_worker_id, true)

        (ENV['SERVERENGINE_WORKER_ID'] || 0).to_i
      end

      # Count a caught record. Errors are logged once and never affect how
      # the record is processed.
      # @param tag [String] log/stream's tag name
      # @param reason [Symbol] why the record was caught (:old, :new or :bad_time)
      # @param action [Symbol] determined action for this record
      def count_record(tag, reason, action)
        return unless @records_counter

        @records_counter.increment(labels: @metric_labels.merge(tag: tag, reason: reason.to_s, action: action.to_s))
      rescue StandardError => e
        return if @metrics_error_logged

        @metrics_error_logged = true
        log.warn "Failed to update metrics, further errors will not be logged: #{e.class}: #{e.message}"
      end

      # Current UNIX time, used as the reference point for the age check.
      # Kept as a separate method so that tests can freeze the clock.
      # @return [Integer] current time in seconds
      def current_time
        Time.now.to_i
      end

      # Format the event time as an ISO 8601 datetime string (in local time).
      # NOTE: Time.at(int) is used instead of EventTime#to_time, which was
      # only added to Fluentd in v1.8.0, and instead of Time.at(EventTime),
      # which relies on Ruby coercing EventTime via #to_r/#to_int. EventTime#to_i
      # is available in all Fluentd releases declared in the gemspec.
      # @param time [Fluent::EventTime] the event time
      # @return [String] ISO 8601-formatted datetime string
      def iso8601(time)
        Time.at(time.to_i).strftime(TIME_ISO8601)
      end

      # Format the event time to a given type/format.
      # @param time [Fluent::EventTime] the original event time
      # @param @source_time_format [Symbol] the target format
      # @return [Integer,Float,String] formatted time as an integer, float (with microseconds), or an ISO8601-formatted datetime string.
      def format_time(time)
        case @source_time_format
        when :epoch
          time.to_i
        when :epoch_float
          time.to_f
        when :iso8601
          iso8601(time)
        end
      end

      # Replace event time and put the old time into a specified field.
      # @param tag [String] log/stream's tag name
      # @param time [Fluent::EventTime] the original event time
      # @param record [Hash] the original record contents
      # @param log_mode [Symbol] log mode for this record
      # @param @source_time_key [String] name of the field to put the old timestamp to.
      # @return [Array] new event time and a modified record.
      def do_replace_timestamp(tag, time, record, log_mode)
        [Fluent::EventTime.now, put_time_key(tag, record, @source_time_key, format_time(time), log_mode)]
      end

      # Put the original time into the given field of a copy of the record,
      # unless the record already has that field and @time_key_conflict says
      # to keep it. The original record is never modified.
      # @param tag [String] log/stream's tag name
      # @param record [Hash] the original record contents
      # @param key [String] name of the field to put the time to
      # @param value the time value to put into the field
      # @param log_mode [Symbol] log mode for this record
      # @return [Hash] the modified copy of the record, or the original record if kept as is
      def put_time_key(tag, record, key, value, log_mode) # rubocop:disable Metrics/ParameterLists
        if record.key?(key) && @time_key_conflict != :overwrite
          log_time_key_conflict(tag, record, key, value, log_mode) if @time_key_conflict == :warn
          return record
        end

        new_record = record.dup
        new_record[key] = value
        new_record
      end

      # Log a time key conflict to Fluentd's log. It is logged even if the
      # record's log mode is :none, since it was asked for explicitly, but the
      # record itself is only included in :full mode.
      # @param tag [String] log/stream's tag name
      # @param record [Hash] the original record contents
      # @param key [String] name of the conflicting field
      # @param value the time value that was not put into the field
      # @param log_mode [Symbol] log mode for this record
      def log_time_key_conflict(tag, record, key, value, log_mode) # rubocop:disable Metrics/ParameterLists
        subject = log_mode == :full ? "#{tag}: #{dump_record(record)}" : tag
        log.warn format(
          'Record already has the "%<key>s" key, keeping its existing value instead of %<val>s: "%<subject>s".',
          key: key, val: value.inspect, subject: subject
        )
      end

      # Log the caught event to Fluentd's log.
      # @param tag [String] log/stream's tag name
      # @param time [Fluent::EventTime] the original event time, or the raw
      #   time for :bad_time records
      # @param record [Hash] the original record contents
      # @param action [Symbol] determined action for this record
      # @param reason [Symbol] why the record was caught (:old, :new or :bad_time)
      # @param log_mode [Symbol] :none, :metadata (no record contents) or :full
      def log_record(tag, time, record, action, reason, log_mode) # rubocop:disable Metrics/ParameterLists
        return if log_mode == :none

        details = reason == :bad_time ? time.inspect : iso8601(time)
        if log_mode == :full
          details = "#{details} #{dump_record(record)}"
        elsif reason != :bad_time
          details = "#{details} (age #{format_age(current_time - time.to_i)})"
        end
        log.warn format(
          'Record caught [%<reason>s, %<act>s]: "%<tag>s: %<details>s".',
          reason: reason, act: action, tag: tag, details: details
        )
      end

      # Format an age in seconds as a compact human-readable string, e.g.
      # "1d 2h 3m 4s", "5m 0s" or "-2h 0m 5s" for times in the future.
      # @param seconds [Integer] the age in seconds
      # @return [String] the formatted age
      def format_age(seconds)
        rest = seconds.abs
        parts = [[86_400, 'd'], [3600, 'h'], [60, 'm'], [1, 's']].map do |size, unit|
          value, rest = rest.divmod(size)
          "#{value}#{unit}"
        end
        parts.shift while parts.size > 1 && parts.first.start_with?('0')
        "#{'-' if seconds.negative?}#{parts.join(' ')}"
      end

      # Serialize the record for logging. Falls back to #inspect when the
      # record can't be represented as JSON (e.g. invalid UTF-8 or NaN), so
      # that a logging failure never affects how the record is processed.
      # @param record [Hash] the original record contents
      # @return [String] the record as a JSON string, or its #inspect output
      def dump_record(record)
        record.to_json
      rescue JSON::GeneratorError, EncodingError
        record.inspect
      end

      # Normalize time to Fluent::EventTime if it's plain int or float, a
      # numeric string or an ISO 8601 datetime string.
      # @param time [Integer|Float|String] incoming event time
      # @return [Fluent::EventTime,nil] event time normalized to Fluentd's internal format, or nil if unparseable
      def normalize_time(time)
        case time
        when Integer
          Fluent::EventTime.new(time)
        when Float
          time_int, time_frac = time.divmod(1)
          Fluent::EventTime.new(time_int, (time_frac * 10**9).to_i)
        else
          if (numeric = coerce_to_number(time))
            normalize_time(numeric)
          elsif (parsed = parse_iso8601(time))
            Fluent::EventTime.new(parsed.to_i, parsed.nsec)
          end
        end
      end

      # Try to coerce an arbitrary value into a number, or return nil.
      # Integer() is called with an explicit base 10 so that zero-padded
      # strings (e.g. "01700000000") aren't parsed as octal.
      # @param value the value to coerce
      # @return [Integer,Float,nil] the parsed number, or nil if not numeric
      def coerce_to_number(value)
        Integer(value, 10, exception: false) || Float(value, exception: false)
      end

      # Try to parse a strict ISO 8601 datetime string, or return nil.
      # Time.iso8601 is used instead of the lenient Time.parse, which would
      # happily turn partial or ambiguous strings into a wrong timestamp.
      # "Relaxed" strings (see ISO8601_RELAXED) are rebuilt as strict ones
      # before parsing. Strings without a UTC offset are treated as local time.
      # @param value the value to parse
      # @return [Time,nil] the parsed time, or nil if not an ISO 8601 string
      def parse_iso8601(value)
        return nil unless value.is_a?(String)

        if (match = ISO8601_RELAXED.match(value))
          zone = match[:zone] == 'UTC' ? 'Z' : match[:zone]
          value = "#{match[:date]}T#{match[:time]}#{zone}"
        end
        Time.iso8601(value)
      rescue ArgumentError
        nil
      end

      # Process the record according to its determined "age"
      # @param tag [String] log/stream's tag name
      # @param time [Fluent::EventTime] the original event time
      # @param record [Hash] the original record contents
      # @param log_mode [Symbol] log mode for this record
      # @param action [Symbol] determined action for this record
      # @param reason [Symbol] why the record was caught (:old or :new)
      def process_record(tag, time, record, log_mode, action, reason) # rubocop:disable Metrics/ParameterLists
        count_record(tag, reason, action)
        log_record(tag, time, record, action, reason, log_mode)

        case action
        when :pass
          [time, record]
        when :replace_timestamp
          do_replace_timestamp(tag, time, record, log_mode)
        when :drop
          nil
        end
      end

      # Process the record with an unparseable time according to the configuration
      # @param tag [String] log/stream's tag name
      # @param time the original (unparseable) event time
      # @param record [Hash] the original record contents
      # @return [Array,nil] current time and the record, or nil if dropped.
      def process_bad_time_record(tag, time, record)
        count_record(tag, :bad_time, @bad_time_action)
        log_record(tag, time, record, @bad_time_action, :bad_time, @bad_time_log)

        case @bad_time_action
        when :replace_timestamp
          do_replace_bad_timestamp(tag, time, record)
        when :drop
          nil
        end
      end

      # Replace unparseable event time and put the raw original time into a
      # separate field. The raw time is always stored as a string, so that the
      # field keeps a stable type for downstream storage. It is not put into
      # @source_time_key, which holds a value in @source_time_format instead.
      # @param tag [String] log/stream's tag name
      # @param time the original (unparseable) event time
      # @param record [Hash] the original record contents
      # @param @bad_time_key [String] name of the field to put the raw time to.
      # @return [Array] new event time and a modified record.
      def do_replace_bad_timestamp(tag, time, record)
        raw_time = time.is_a?(String) ? time : time.inspect
        [Fluent::EventTime.now, put_time_key(tag, record, @bad_time_key, raw_time, @bad_time_log)]
      end

      # Process the "old" record according to the configuration
      # @param tag [String] log/stream's tag name
      # @param time [Fluent::EventTime] the original event time
      # @param record [Hash] the original record contents
      def process_old_record(tag, time, record)
        process_record(tag, time, record, @old_log, @old_action, :old)
      end

      # Process the "new" record according to the configuration
      # @param tag [String] log/stream's tag name
      # @param time [Fluent::EventTime] the original event time
      # @param record [Hash] the original record contents
      def process_new_record(tag, time, record)
        process_record(tag, time, record, @new_log, @new_action, :new)
      end
    end
  end
end
