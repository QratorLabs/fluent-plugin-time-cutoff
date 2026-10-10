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
      assert_equal :replace_timestamp, d.instance.bad_time_action
      assert_true d.instance.bad_time_log
      assert_equal 'source_time_raw', d.instance.bad_time_key
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

    test 'rejects unknown unparseable time actions' do
      assert_raise(Fluent::ConfigError) do
        create_driver('bad_time_action pass')
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

  sub_test_case 'non-EventTime input' do
    test 'raw integer time inside the window is normalized to EventTime' do
      t = Time.now.to_i - 3600
      d = filter("old_action drop\nnew_action drop", t)
      assert_equal [RECORD], d.filtered_records
      assert_kind_of Fluent::EventTime, d.filtered_time.first
      assert_equal t, d.filtered_time.first.sec
    end

    test 'raw integer time past the cutoff is detected' do
      d = filter('old_action drop', Time.now.to_i - 100_000)
      assert_empty d.filtered_records
    end

    test 'raw float time inside the window keeps sub-second precision' do
      t = Time.now.to_i - 3600
      d = filter('old_action drop', t + 0.5)
      assert_equal t, d.filtered_time.first.sec
      assert_in_delta 500_000_000, d.filtered_time.first.nsec, 1
    end

    test 'string time is classified by its parsed value, not String#to_i' do
      # "1.79e+09".to_i == 1, which used to look like a 1970 timestamp.
      t = Time.now.to_i - 3600
      d = filter('old_action drop', format('%.10e', t))
      assert_equal [RECORD], d.filtered_records
      assert_equal t, d.filtered_time.first.sec
    end

    test 'string time past the cutoff is detected' do
      d = filter('old_action drop', (Time.now.to_i - 100_000).to_s)
      assert_empty d.filtered_records
    end

    test 'ISO 8601 string time inside the window is kept with its real time' do
      t = Time.now.to_i - 3600
      d = filter('old_action drop', Time.at(t).strftime('%FT%T%:z'))
      assert_equal [RECORD], d.filtered_records
      assert_equal t, d.filtered_time.first.sec
    end

    test 'ISO 8601 string time past the cutoff is detected' do
      d = filter('old_action drop', Time.at(Time.now.to_i - 100_000).strftime('%FT%T%:z'))
      assert_empty d.filtered_records
    end

    test 'ISO 8601 string time is preserved by replace_timestamp' do
      t = Time.now.to_i - 100_000
      iso = Time.at(t).strftime('%FT%T%:z')
      d = filter('old_action replace_timestamp', iso)
      assert_equal iso, d.filtered_records.first['source_time']
    end

    test 'unparseable time is replaced with now and kept by default' do
      d = filter('old_action drop', 'not-a-time')
      assert_equal [RECORD.merge('source_time_raw' => 'not-a-time')], d.filtered_records
      assert_in_delta Time.now.to_i, d.filtered_time.first.sec, 5
      warnings = d.logs.select { |l| l.include?('[warn]') }
      assert_equal 1, warnings.size
      assert_match(/\[unparseable, replace_timestamp\].*"not-a-time"/, warnings.first)
    end

    test 'unparseable time is replaced with now when configured explicitly' do
      d = filter("old_action drop\nbad_time_action replace_timestamp", nil)
      assert_equal 1, d.filtered.size
      assert_in_delta Time.now.to_i, d.filtered_time.first.sec, 5
    end

    test 'replace_timestamp stores the raw unparseable time in bad_time_key' do
      d = filter('bad_time_action replace_timestamp', 'not-a-time')
      record = d.filtered_records.first
      assert_equal 'hello', record['message']
      assert_equal 'not-a-time', record['source_time_raw']
      assert_false record.key?('source_time')
    end

    data(
      'nil' => [nil, 'nil'],
      'symbol' => [:soon, ':soon'],
      'array' => [[1, 2], '[1, 2]']
    )
    test 'replace_timestamp stores non-string raw times as their inspect output' do |(raw, stored)|
      d = filter('bad_time_action replace_timestamp', raw)
      assert_equal stored, d.filtered_records.first['source_time_raw']
    end

    test 'replace_timestamp honors a custom bad_time_key' do
      d = filter("bad_time_action replace_timestamp\nbad_time_key broken_time", 'not-a-time')
      record = d.filtered_records.first
      assert_equal 'not-a-time', record['broken_time']
      assert_false record.key?('source_time_raw')
    end

    test 'replace_timestamp does not mutate the input record on bad time' do
      filter('bad_time_action replace_timestamp', 'not-a-time')
      assert_false RECORD.key?('source_time_raw')
    end

    test 'parseable times do not get a bad_time_key' do
      d = filter('old_action replace_timestamp', (Time.now.to_i - 100_000).to_s)
      record = d.filtered_records.first
      assert_true record.key?('source_time')
      assert_false record.key?('source_time_raw')
    end

    test 'unparseable time drops the record when configured' do
      d = filter('bad_time_action drop', 'not-a-time')
      assert_empty d.filtered
      assert_empty d.error_events
      warnings = d.logs.select { |l| l.include?('[warn]') }
      assert_equal 1, warnings.size
      assert_match(/\[unparseable, drop\].*"not-a-time"/, warnings.first)
      assert_match(/test\.cutoff/, warnings.first)
      assert_match(/\{"message":"hello"\}/, warnings.first)
    end

    data(
      'replace_timestamp' => ['replace_timestamp', 1],
      'drop' => ['drop', 0]
    )
    test 'bad_time_log false silences the log but keeps the action' do |(action, count)|
      d = filter("bad_time_action #{action}\nbad_time_log false", 'not-a-time')
      assert_equal count, d.filtered.size
      assert_false(d.logs.any? { |l| l.include?('[warn]') })
    end

    test 'bad_time_action does not affect parseable times' do
      t = Time.now.to_i - 3600
      d = filter('bad_time_action drop', Time.at(t).strftime('%F %T %z'))
      assert_equal [RECORD], d.filtered_records
      assert_equal t, d.filtered_time.first.sec
    end

    test 'parseable string time is not warned about' do
      d = filter('old_action drop', Time.at(Time.now.to_i - 3600).strftime('%FT%T%:z'))
      assert_false(d.logs.any? { |l| l.include?('[warn]') })
    end
  end

  sub_test_case 'logging' do
    test 'logs caught records as JSON' do
      d = filter('old_action pass', ago(100_000))
      assert_true(d.logs.any? { |l| l.include?('[old, pass]') && l.include?('{"message":"hello"}') })
    end

    test 'records that cannot be JSON-encoded are still processed' do
      record = { 'message' => "\xFF".b }
      d = filter('old_action pass', ago(100_000), record)
      assert_empty d.error_events
      assert_equal [record], d.filtered_records
      assert_true(d.logs.any? { |l| l.include?('[old, pass]') && l.include?('\xFF') })
    end

    test 'logging is skipped when disabled' do
      d = filter("old_action pass\nold_log false", ago(100_000))
      assert_false(d.logs.any? { |l| l.include?('Record caught') })
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
      @driver = create_driver('')
      @instance = @driver.instance
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

    test 'parses a zero-padded numeric string as decimal' do
      result = @instance.send(:normalize_time, '01700000000')
      assert_equal 1_700_000_000, result.sec
    end

    test 'parses a float string, keeping sub-second precision' do
      result = @instance.send(:normalize_time, '1700000000.25')
      assert_equal 1_700_000_000, result.sec
      assert_in_delta 250_000_000, result.nsec, 1
    end

    test 'returns nil for a nil value' do
      assert_nil @instance.send(:normalize_time, nil)
    end

    test 'parses an ISO 8601 string with a UTC designator' do
      result = @instance.send(:normalize_time, '2023-11-14T22:13:20Z')
      assert_equal 1_700_000_000, result.sec
      assert_equal 0, result.nsec
    end

    test 'parses an ISO 8601 string with an offset and fractional seconds' do
      result = @instance.send(:normalize_time, '2023-11-15T01:13:20.25+03:00')
      assert_equal 1_700_000_000, result.sec
      assert_equal 250_000_000, result.nsec
    end

    test 'parses an ISO 8601 string with a space instead of T' do
      result = @instance.send(:normalize_time, '2023-11-15 01:13:20.25+03:00')
      assert_equal 1_700_000_000, result.sec
      assert_equal 250_000_000, result.nsec
    end

    test 'parses a space-separated ISO 8601 string with a UTC designator' do
      result = @instance.send(:normalize_time, '2023-11-14 22:13:20Z')
      assert_equal 1_700_000_000, result.sec
    end

    data(
      'colon offset' => '2023-11-15 01:13:20 +03:00',
      'basic offset (Time#to_s)' => '2023-11-15 01:13:20 +0300',
      'hours-only offset' => '2023-11-15 01:13:20 +03',
      'negative offset' => '2023-11-14 19:13:20 -03:00',
      'spaced Z' => '2023-11-14 22:13:20 Z',
      'UTC (Time#to_s)' => '2023-11-14 22:13:20 UTC',
      'T separator and spaced offset' => '2023-11-15T01:13:20 +03:00'
    )
    test 'parses ISO 8601 strings with a space before the timezone' do |value|
      result = @instance.send(:normalize_time, value)
      assert_equal 1_700_000_000, result.sec
    end

    test 'parses a spaced timezone with fractional seconds (Time#inspect)' do
      result = @instance.send(:normalize_time, '2023-11-15 01:13:20.25 +0300')
      assert_equal 1_700_000_000, result.sec
      assert_equal 250_000_000, result.nsec
    end

    data(
      'double space before offset' => '2023-11-15 01:13:20  +03:00',
      'unknown zone name' => '2023-11-15 01:13:20 MSK',
      'garbage after offset' => '2023-11-15 01:13:20 +03:00 x'
    )
    test 'rejects malformed spaced timezones' do |value|
      assert_nil @instance.send(:normalize_time, value)
    end

    test 'does not guess at non-ISO 8601 date strings' do
      assert_nil @instance.send(:normalize_time, 'Nov 14 2023')
    end

    test 'returns nil for a non-numeric value' do
      assert_nil @instance.send(:normalize_time, 'not-a-time')
    end

    test 'does not log anything itself' do
      @instance.send(:normalize_time, '1700000000')
      @instance.send(:normalize_time, '2023-11-14T22:13:20Z')
      @instance.send(:normalize_time, 'not-a-time')
      assert_false(@driver.logs.any? { |l| l.include?('[warn]') })
    end
  end

  private

  # Feed a single record at the given time through a configured driver.
  # Events are fed as an array so that non-EventTime times (Float, String,
  # nil) reach the plugin as-is.
  def filter(conf, time, record = RECORD)
    d = create_driver(conf)
    d.run(default_tag: 'test.cutoff') do
      d.feed([[time, record]])
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
