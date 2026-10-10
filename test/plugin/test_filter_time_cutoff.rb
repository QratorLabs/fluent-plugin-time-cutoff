require 'helper'
require 'fluent/plugin/filter_time_cutoff.rb'

class TimeCutoffFilterTest < Test::Unit::TestCase
  setup do
    Fluent::Test.setup
  end

  RECORD = { 'message' => 'hello' }.freeze

  # A fixed "current time" for tests that need a frozen clock.
  NOW = 1_700_000_000

  sub_test_case 'configuration' do
    test 'loads sane defaults' do
      d = create_driver('')
      assert_equal 86_400, d.instance.old_cutoff
      assert_equal 86_400, d.instance.new_cutoff
      assert_equal :pass, d.instance.old_action
      assert_equal :pass, d.instance.new_action
      assert_equal :full, d.instance.old_log
      assert_equal :full, d.instance.new_log
      assert_equal 'source_time', d.instance.source_time_key
      assert_equal :iso8601, d.instance.source_time_format
      assert_equal :replace_timestamp, d.instance.bad_time_action
      assert_equal :full, d.instance.bad_time_log
      assert_equal 'source_time_raw', d.instance.bad_time_key
      assert_equal :skip, d.instance.time_key_conflict
      assert_false d.instance.metrics
    end

    data(
      'false' => ['false', :none],
      'no' => ['no', :none],
      'none' => ['none', :none],
      'metadata' => ['metadata', :metadata],
      'full' => ['full', :full],
      'true' => ['true', :full],
      'yes' => ['yes', :full]
    )
    test 'log options accept log modes and boolean aliases' do |(value, mode)|
      d = create_driver("old_log #{value}\nnew_log #{value}\nbad_time_log #{value}")
      assert_equal mode, d.instance.old_log
      assert_equal mode, d.instance.new_log
      assert_equal mode, d.instance.bad_time_log
    end

    test 'rejects unknown log modes' do
      assert_raise(Fluent::ConfigError) do
        create_driver('old_log verbose')
      end
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

    data(
      'negative old_cutoff' => 'old_cutoff -3600',
      'negative new_cutoff' => 'new_cutoff -1',
      'negative cutoff with a unit' => 'old_cutoff -1h',
      'negative cutoff with leading spaces' => 'new_cutoff "  -1h"',
      'empty source_time_key' => 'source_time_key ""',
      'empty bad_time_key' => 'bad_time_key ""',
      'same keys' => "source_time_key t\nbad_time_key t"
    )
    test 'rejects invalid settings' do |conf|
      assert_raise(Fluent::ConfigError) do
        create_driver(conf)
      end
    end

    test 'accepts zero cutoffs' do
      d = create_driver("old_cutoff 0\nnew_cutoff 0")
      assert_equal 0, d.instance.old_cutoff
      assert_equal 0, d.instance.new_cutoff
    end

    test 'rejects unknown time key conflict actions' do
      assert_raise(Fluent::ConfigError) do
        create_driver('time_key_conflict merge')
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

    # The clock is frozen for the exact-edge tests below, so that a second
    # boundary passing between feeding the record and checking it can't
    # make them flaky.
    test 'records exactly at the old cutoff edge are kept' do
      # event_time == now - old_cutoff is NOT "< now - old_cutoff", so it stays.
      d = filter("old_cutoff 1h\nold_action drop", at(NOW - 3600), now: NOW)
      assert_equal [RECORD], d.filtered_records
    end

    test 'records one second past the old cutoff edge are caught' do
      d = filter("old_cutoff 1h\nold_action drop", at(NOW - 3601), now: NOW)
      assert_empty d.filtered_records
    end

    test 'records exactly at the new cutoff edge are kept' do
      d = filter("new_cutoff 1h\nnew_action drop", at(NOW + 3600), now: NOW)
      assert_equal [RECORD], d.filtered_records
    end

    test 'records one second past the new cutoff edge are caught' do
      d = filter("new_cutoff 1h\nnew_action drop", at(NOW + 3601), now: NOW)
      assert_empty d.filtered_records
    end

    test 'sub-second precision does not move the edge' do
      d = filter("old_cutoff 1h\nold_action drop", Fluent::EventTime.new(NOW - 3600, 999_999_999), now: NOW)
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
      assert_match(/\[bad_time, replace_timestamp\].*"not-a-time"/, warnings.first)
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
      assert_match(/\[bad_time, drop\].*"not-a-time"/, warnings.first)
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

  sub_test_case 'time_key_conflict' do
    # Old records get their time replaced and the original put into
    # source_time_key; records with a bad time get the raw time put into
    # bad_time_key. Both keys already exist in these records.
    EXISTING = { 'message' => 'hello', 'source_time' => 'earlier', 'source_time_raw' => 'earlier raw' }.freeze

    def old_record(conf)
      filter("old_action replace_timestamp\nold_log false\n#{conf}", ago(100_000), EXISTING)
    end

    def bad_time_record(conf)
      filter("bad_time_action replace_timestamp\nbad_time_log false\n#{conf}", 'not-a-time', EXISTING)
    end

    def warnings(driver)
      driver.logs.select { |l| l.include?('[warn]') }
    end

    data('source_time_key' => [:old_record, 'source_time'],
         'bad_time_key' => [:bad_time_record, 'source_time_raw'])
    test 'skip keeps the existing value silently by default' do |(feed, key)|
      d = send(feed, '')
      new_time, record = d.filtered.first
      assert_equal EXISTING[key], record[key]
      assert_in_delta Time.now.to_i, new_time.to_i, 5
      assert_empty warnings(d)
    end

    data('source_time_key' => [:old_record, 'source_time'],
         'bad_time_key' => [:bad_time_record, 'source_time_raw'])
    test 'warn keeps the existing value and logs a warning' do |(feed, key)|
      d = send(feed, 'time_key_conflict warn')
      new_time, record = d.filtered.first
      assert_equal EXISTING[key], record[key]
      assert_in_delta Time.now.to_i, new_time.to_i, 5
      assert_equal 1, warnings(d).size
      assert_match(/"#{key}" key/, warnings(d).first)
      assert_match(/test\.cutoff/, warnings(d).first)
    end

    data('source_time_key' => [:old_record, 'source_time'],
         'bad_time_key' => [:bad_time_record, 'source_time_raw'])
    test 'overwrite replaces the existing value silently' do |(feed, key)|
      d = send(feed, 'time_key_conflict overwrite')
      record = d.filtered_records.first
      assert_not_equal EXISTING[key], record[key]
      assert_empty warnings(d)
    end

    test 'overwrite stores the formatted original time' do
      t = ago(100_000)
      d = filter("old_action replace_timestamp\ntime_key_conflict overwrite", t, EXISTING)
      assert_equal Time.at(t.to_i).strftime('%FT%T%:z'), d.filtered_records.first['source_time']
    end

    test 'no conflict handling happens when the key is absent' do
      d = filter("old_action replace_timestamp\nold_log false\ntime_key_conflict warn", ago(100_000))
      assert_true d.filtered_records.first.key?('source_time')
      assert_empty warnings(d)
    end

    test 'the input record is never mutated' do
      %w[skip warn overwrite].each do |mode|
        old_record("time_key_conflict #{mode}")
        bad_time_record("time_key_conflict #{mode}")
      end
      assert_equal({ 'message' => 'hello', 'source_time' => 'earlier', 'source_time_raw' => 'earlier raw' }, EXISTING)
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

    test 'logging is skipped with log mode none' do
      d = filter("new_action pass\nnew_log none", ahead(100_000))
      assert_false(d.logs.any? { |l| l.include?('Record caught') })
    end

    def caught(driver)
      driver.logs.select { |l| l.include?('Record caught') }
    end

    test 'metadata mode logs tag, time and age without the record' do
      d = filter("old_cutoff 1h\nold_action drop\nold_log metadata", at(NOW - 93_784), now: NOW)
      lines = caught(d)
      assert_equal 1, lines.size
      assert_match(/\[old, drop\]: "test\.cutoff: #{Regexp.escape(Time.at(NOW - 93_784).strftime('%FT%T%:z'))} \(age 1d 2h 3m 4s\)"\./, lines.first)
      assert_not_match(/hello/, lines.first)
    end

    test 'metadata mode shows a negative age for records from the future' do
      d = filter("new_cutoff 1h\nnew_action pass\nnew_log metadata", at(NOW + 7_205), now: NOW)
      assert_match(/\[new, pass\]: "test\.cutoff: \S+ \(age -2h 0m 5s\)"\./, caught(d).first)
    end

    data(
      'seconds' => [59, '59s'],
      'zero' => [0, '0s'],
      'minutes' => [60, '1m 0s'],
      'days' => [86_400 * 400, '400d 0h 0m 0s']
    )
    test 'formats ages compactly' do |(seconds, text)|
      assert_equal text, create_driver('').instance.send(:format_age, seconds)
    end

    test 'metadata mode logs the raw bad time without the record' do
      d = filter("bad_time_action drop\nbad_time_log metadata", 'not-a-time')
      lines = caught(d)
      assert_equal 1, lines.size
      assert_match(/\[bad_time, drop\]: "test\.cutoff: "not-a-time""\./, lines.first)
      assert_not_match(/hello/, lines.first)
    end

    test 'full mode still logs the record' do
      d = filter("bad_time_action drop\nbad_time_log full", 'not-a-time')
      assert_match(/\[bad_time, drop\]: "test\.cutoff: "not-a-time" \{"message":"hello"\}"\./, caught(d).first)
    end

    data(
      'full' => ['full', true],
      'metadata' => ['metadata', false],
      'none' => ['none', false]
    )
    test 'time key conflict warnings follow the log mode' do |(mode, with_record)|
      record = { 'message' => 'hello', 'source_time' => 'earlier' }
      d = filter("old_action replace_timestamp\nold_log #{mode}\ntime_key_conflict warn", ago(100_000), record)
      warning = d.logs.grep(/already has the "source_time" key/)
      assert_equal 1, warning.size
      assert_equal with_record, warning.first.include?('hello')
    end
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
  # Pass "now:" to freeze the plugin's clock at that UNIX time.
  def filter(conf, time, record = RECORD, now: nil)
    d = create_driver(conf)
    d.instance.define_singleton_method(:current_time) { now } if now
    d.run(default_tag: 'test.cutoff') do
      d.feed([[time, record]])
    end
    d
  end

  def at(seconds)
    Fluent::EventTime.new(seconds)
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
