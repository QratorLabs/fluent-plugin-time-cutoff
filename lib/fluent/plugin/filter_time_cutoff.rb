# frozen_string_literal: true

require 'fluent/plugin/filter'
require 'json'
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
      desc 'Log the "old" messages to Fluentd\'s own log. Defaults to "true".'
      config_param :old_log, :bool, default: true
      desc 'Records newer than this amount of time are deemed "new". Defaults to 24 hours.'
      config_param :new_cutoff, :time, default: 86_400 # 24 hours
      desc 'The action that will be performed to all "new" messages. Defaults to passthrough.'
      config_param :new_action, :enum, list: CUTOFF_ACTIONS, default: :pass
      desc 'Log the "new" messages to Fluentd\'s own log. Defaults to "true".'
      config_param :new_log, :bool, default: true
      desc 'The key that will hold the original time (for :replace_timestamp action). Defaults to "source_time".'
      config_param :source_time_key, :string, default: 'source_time'
      desc 'Time format for the original timestamp field. Defaults to ISO8601-formatted string.'
      config_param :source_time_format, :enum, list: TIME_FORMATS, default: :iso8601
      desc 'The action that will be performed to all messages with an unparseable time. Defaults to replacing it with current time.'
      config_param :bad_time_action, :enum, list: BAD_TIME_ACTIONS, default: :replace_timestamp
      desc 'Log the messages with an unparseable time to Fluentd\'s own log. Defaults to "true".'
      config_param :bad_time_log, :bool, default: true
      desc 'The key that will hold the original unparseable time (for :replace_timestamp action). Defaults to "source_time_raw".'
      config_param :bad_time_key, :string, default: 'source_time_raw'

      def filter_with_time(tag, time, record)
        ## Safeguard against rogue integer/float/string time. This has to happen
        ## before classification, so that the age check uses the parsed value.
        unless time.is_a?(Fluent::EventTime)
          normalized = normalize_time(time)
          return process_bad_time_record(tag, time, record) if normalized.nil?

          time = normalized
        end

        event_time = time.to_i
        current_time = Time.now.to_i

        if event_time < current_time - @old_cutoff
          # Too old
          process_old_record(tag, time, record)
        elsif event_time > current_time + @new_cutoff
          # Too new
          process_new_record(tag, time, record)
        else
          # OK
          [time, record]
        end
      end

      private

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
          # NOTE: Time.at(int) is used instead of EventTime#to_time, which was
          # only added to Fluentd in v1.8.0. This keeps us compatible with the
          # older Fluentd releases declared in the gemspec.
          Time.at(time.to_i).strftime(TIME_ISO8601)
        end
      end

      # Replace event time and put the old time into a specified field.
      # @param time [Fluent::EventTime] the original event time
      # @param record [Hash] the original record contents
      # @param @source_time_key [String] name of the field to put the old timestamp to.
      # @return [Array] new event time and a modified record.
      def do_replace_timestamp(time, record)
        new_time = Fluent::EventTime.now
        new_record = record.dup
        old_time = format_time(time)
        new_record[@source_time_key] = old_time

        [new_time, new_record]
      end

      # Log the caught event to Fluentd's log.
      # @param tag [String] log/stream's tag name
      # @param time [Fluent::EventTime] the original event time
      # @param record [Hash] the original record contents
      # @param action [Symbol] determined action for this record
      # @param age [Symbol] detemined age for this record (:old or :new)
      def log_record(tag, time, record, action, age)
        fmt_time = Time.at(time).strftime(TIME_ISO8601)
        log_line = format(
          'Record caught [%<age>s, %<act>s]: "%<tag>s: %<time>s %<msg>s".',
          age: age, act: action, tag: tag, time: fmt_time, msg: dump_record(record)
        )
        log.warn log_line
      end

      # Log the caught event with an unparseable time to Fluentd's log.
      # @param tag [String] log/stream's tag name
      # @param time the original (unparseable) event time
      # @param record [Hash] the original record contents
      # @param action [Symbol] determined action for this record
      def log_bad_time_record(tag, time, record, action)
        log_line = format(
          'Record caught [unparseable, %<act>s]: "%<tag>s: %<time>s %<msg>s".',
          act: action, tag: tag, time: time.inspect, msg: dump_record(record)
        )
        log.warn log_line
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
      # @param do_log [Boolean] should we log this record or not
      # @param action [Symbol] determined action for this record
      # @param age [Symbol] detemined age for this record (:old or :new)
      def process_record(tag, time, record, do_log, action, age) # rubocop:disable Metrics/ParameterLists
        log_record(tag, time, record, action, age) if do_log

        case action
        when :pass
          [time, record]
        when :replace_timestamp
          do_replace_timestamp(time, record)
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
        log_bad_time_record(tag, time, record, @bad_time_action) if @bad_time_log

        case @bad_time_action
        when :replace_timestamp
          do_replace_bad_timestamp(time, record)
        when :drop
          nil
        end
      end

      # Replace unparseable event time and put the raw original time into a
      # separate field. The raw time is always stored as a string, so that the
      # field keeps a stable type for downstream storage. It is not put into
      # @source_time_key, which holds a value in @source_time_format instead.
      # @param time the original (unparseable) event time
      # @param record [Hash] the original record contents
      # @param @bad_time_key [String] name of the field to put the raw time to.
      # @return [Array] new event time and a modified record.
      def do_replace_bad_timestamp(time, record)
        new_record = record.dup
        new_record[@bad_time_key] = time.is_a?(String) ? time : time.inspect

        [Fluent::EventTime.now, new_record]
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
