require 'helper'
require 'fluent/plugin/filter_time_cutoff.rb'

class TimeCutoffFilterTest < Test::Unit::TestCase
  setup do
    Fluent::Test.setup
  end

  RECORD = { 'message' => 'hello' }.freeze

  sub_test_case 'configuration' do
    test 'loads sane defaults' do
      d = create_driver('')
      assert_equal 86_400, d.instance.old_cutoff
      assert_equal 86_400, d.instance.new_cutoff
      assert_equal :pass, d.instance.old_action
      assert_equal :pass, d.instance.new_action
      assert_true d.instance.old_log
      assert_true d.instance.new_log
      assert_equal 'source_time', d.instance.source_time_key
      assert_equal :iso8601, d.instance.source_time_format
    end

    test 'parses human-readable durations' do
      d = create_driver('old_cutoff 12h')
      assert_equal 12 * 3600, d.instance.old_cutoff
    end

    test 'rejects unknown actions' do
      assert_raise(Fluent::ConfigError) do
        create_driver('old_action explode')
      end
    end

    test 'rejects unknown time formats' do
      assert_raise(Fluent::ConfigError) do
        create_driver('source_time_format rfc3339')
      end
    end
  end

  sub_test_case 'window boundaries' do
    test 'passes records inside the window untouched' do
      d = filter("old_action drop\nnew_action drop", ago(3600))
      assert_equal [RECORD], d.filtered_records
    end

    test 'records exactly at the cutoff edge are kept' do
      # event_time == now - old_cutoff is NOT "< now - old_cutoff", so it stays.
      d = filter("old_cutoff 1h\nold_action drop", ago(3600))
      assert_equal [RECORD], d.filtered_records
    end

    test 'detects old records past the cutoff' do
      d = filter("old_cutoff 1h\nold_action drop", ago(100_000))
      assert_empty d.filtered_records
    end

    test 'detects new records past the cutoff' do
      d = filter("new_cutoff 1h\nnew_action drop", ahead(100_000))
      assert_empty d.filtered_records
    end
  end

  sub_test_case 'actions' do
    test 'pass keeps both time and record' do
      t = ago(100_000)
      d = filter('old_action pass', t)
      assert_equal [RECORD], d.filtered_records
      assert_in_delta t.to_i, d.filtered_time.first.to_i, 1
    end

    test 'drop removes old records' do
      d = filter('old_action drop', ago(100_000))
      assert_empty d.filtered
    end

    test 'drop removes new records' do
      d = filter('new_action drop', ahead(100_000))
      assert_empty d.filtered
    end

    test 'replace_timestamp rewrites time to now and preserves the original' do
      original = ago(100_000)
      d = filter('old_action replace_timestamp', original)

      new_time, record = d.filtered.first
      assert_in_delta Time.now.to_i, new_time.to_i, 5
      assert_equal 'hello', record['message']
      assert_equal Time.at(original.to_i).strftime('%FT%T%:z'),
                   record['source_time']
    end

    test 'replace_timestamp does not mutate the input record' do
      d = filter('old_action replace_timestamp', ago(100_000))
      assert_false RECORD.key?('source_time')
      assert_equal 'hello', d.filtered_records.first['message']
    end
  end

  sub_test_case 'source_time_format' do
    test 'epoch stores an integer' do
      t = ago(100_000)
      d = filter("old_action replace_timestamp\nsource_time_format epoch", t)
      stored = d.filtered_records.first['source_time']
      assert_kind_of Integer, stored
      assert_equal t.to_i, stored
    end

    test 'epoch_float stores a float' do
      t = ago(100_000)
      d = filter("old_action replace_timestamp\nsource_time_format epoch_float", t)
      stored = d.filtered_records.first['source_time']
      assert_kind_of Float, stored
      assert_in_delta t.to_f, stored, 0.001
    end

    test 'iso8601 stores a formatted string' do
      t = ago(100_000)
      d = filter("old_action replace_timestamp\nsource_time_format iso8601", t)
      stored = d.filtered_records.first['source_time']
      assert_kind_of String, stored
      assert_equal Time.at(t.to_i).strftime('%FT%T%:z'), stored
    end

    test 'honors a custom source_time_key' do
      d = filter("old_action replace_timestamp\nsource_time_key was_at", ago(100_000))
      record = d.filtered_records.first
      assert_true record.key?('was_at')
      assert_false record.key?('source_time')
    end
  end

  sub_test_case '#normalize_time' do
    setup do
      @instance = create_driver('').instance
    end

    test 'wraps a plain integer without warning' do
      result = @instance.send(:normalize_time, 1_700_000_000)
      assert_kind_of Fluent::EventTime, result
      assert_equal 1_700_000_000, result.sec
      assert_equal 0, result.nsec
    end

    test 'wraps a plain float, keeping sub-second precision' do
      result = @instance.send(:normalize_time, 1_700_000_000.5)
      assert_kind_of Fluent::EventTime, result
      assert_equal 1_700_000_000, result.sec
      assert_in_delta 500_000_000, result.nsec, 1
    end

    test 'parses a numeric string' do
      result = @instance.send(:normalize_time, '1700000000')
      assert_kind_of Fluent::EventTime, result
      assert_equal 1_700_000_000, result.sec
    end

    test 'falls back to now for a non-numeric value' do
      result = @instance.send(:normalize_time, 'not-a-time')
      assert_kind_of Fluent::EventTime, result
      assert_in_delta Time.now.to_i, result.sec, 5
    end
  end

  private

  # Feed a single record at the given time through a configured driver.
  def filter(conf, time, record = RECORD)
    d = create_driver(conf)
    d.run(default_tag: 'test.cutoff') do
      d.feed(time, record)
    end
    d
  end

  def ago(seconds)
    Fluent::EventTime.new((Time.now - seconds).to_i)
  end

  def ahead(seconds)
    Fluent::EventTime.new((Time.now + seconds).to_i)
  end

  def create_driver(conf)
    Fluent::Test::Driver::Filter.new(Fluent::Plugin::TimeCutoffFilter).configure(conf)
  end
end
