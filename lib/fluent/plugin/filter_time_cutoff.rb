# frozen_string_literal: true

require 'fluent/plugin/filter'
require 'json'
require 'time'

module Fluent
  module Plugin
    class TimeCutoffFilter < Fluent::Plugin::Filter
      CUTOFF_ACTIONS = [
        # Pass record as is:
        :pass,
        # Replace time with "now" and pass:
        :replace_timestamp,
        # Drop record as invalid:
        :drop
      ].freeze

      TIME_FORMATS = [
        # UNIX time (integer)
        :epoch,
        # UNIX time (float)
        :epoch_float,
        # ISO 8601 datetime (string)
        :iso8601
      ].freeze

      TIME_ISO8601 = '%FT%T%:z'

      Fluent::Plugin.register_filter('time_cutoff', self)
      ## Records older than this are deemed "old":
      config_param :old_cutoff, :time, default: 86_400 # 24 hours
      ## What to do with "old" records:
      config_param :old_action, :enum, list: CUTOFF_ACTIONS, default: :pass
      ## Print the "old" records to Fluentd's log:
      config_param :old_log, :bool, default: true
      ## Records newer than this are deemed "new":
      config_param :new_cutoff, :time, default: 86_400 # 24 hours
      ## What to do with "new" records:
      config_param :new_action, :enum, list: CUTOFF_ACTIONS, default: :pass
      ## Print the "new" records to Fluentd's log:
      config_param :new_log, :bool, default: true
      ## Name of the key that will hold original timestamp
      #  (for action = :replace_timestamp):
      config_param :source_time_key, :string, default: 'source_time'
      ## How to format the original time (for action = :replace_timestamp):
      config_param :source_time_format, :enum, list: TIME_FORMATS, default: :as_string

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

      def do_replace_timestamp(time, record)
        new_time = Fluent::EventTime.now
        new_record = record.dup
        old_time = format_time(time)
        new_record[@source_time_key] = old_time

        [new_time, new_record]
      end

      def log_record(tag, time, record, action, age)
        fmt_time = Time.at(time).strftime(TIME_ISO8601)
        log_line = format(
          'Record caught [%<age>s, %<act>s]: "%<tag>s: %<time>s %<msg>s".',
          age: age, act: action, tag: tag, time: fmt_time, msg: record.to_json
        )
        log.warn log_line
      end

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

      def process_old_record(tag, time, record)
        process_record(tag, time, record, @old_log, @old_action, :old)
      end

      def process_new_record(tag, time, record)
        process_record(tag, time, record, @new_log, @new_action, :new)
      end
    end
  end
end
