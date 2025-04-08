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

      # strftime() format string for :iso8601 time format.
      TIME_ISO8601 = '%FT%T%:z'

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

      def filter_with_time(tag, time, record)
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
          time.to_time.strftime(TIME_ISO8601)
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
          age: age, act: action, tag: tag, time: fmt_time, msg: record.to_json
        )
        log.warn log_line
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
