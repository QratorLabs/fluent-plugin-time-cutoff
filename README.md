# fluent-plugin-time-cutoff

[Fluentd](https://fluentd.org/) filter plugin to cut off log records with a timestamp outside of given window.

## Examples

### Example 1: Delete all logs older than 12 hours, pass through records from the future

**Configuration**

``` xml
<filter **>
  @type time_cutoff
  @id time_cutoff
 
  old_cutoff 12h
  old_action drop

  new_action pass
  new_log false
</filter>
```

**Input**

``` bash
# Local time is 2025-04-08T14:43:14+03:00
fluent-cat --event-time '2025-04-08T02:42:00+03:00' test.cutoff <<< '{"message": "hello"}'
fluent-cat --event-time '2025-04-08T12:42:00+03:00' test.cutoff <<< '{"message": "hello"}'
fluent-cat --event-time '2025-04-09T14:42:00+03:00' test.cutoff <<< '{"message": "hello"}'
```

**Output**

```
2025-04-08 14:43:24 +0300 [warn]: [time_cutoff] Record caught [old, drop]: "test.cutoff: 2025-04-08T02:42:00+03:00 {"message":"hello"}".
2025-04-08 12:42:00.000000000 +0300 test.cutoff: {"message":"hello"}
2025-04-09 14:42:00.000000000 +0300 test.cutoff: {"message":"hello"}
```

### Example 2: Delete all logs older than 24 hours (omit log), rewrite timestamps for all records newer than 3 hours:

**Configuration**

``` xml
<filter **>
  @type time_cutoff
  @id time_cutoff
 
  old_cutoff 24h
  old_action drop
  old_log false

  new_cutoff 3h
  new_action replace_timestamp
</filter>
```

**Input**

``` bash
# Local time is 2025-04-08T14:48:42+03:00
fluent-cat --event-time '2025-04-07T14:48:00+03:00' test.cutoff <<< '{"message": "hello"}'
fluent-cat --event-time '2025-04-08T14:48:00+03:00' test.cutoff <<< '{"message": "hello"}'
fluent-cat --event-time '2025-04-08T18:48:00+03:00' test.cutoff <<< '{"message": "hello"}'
```

**Output**

```
2025-04-08 14:48:00.000000000 +0300 test.cutoff: {"message":"hello"}
2025-04-08 14:49:13 +0300 [warn]: [time_cutoff] Record caught [new, replace_timestamp]: "test.cutoff: 2025-04-08T18:48:00+03:00 {"message":"hello"}".
2025-04-08 14:49:13.090783000 +0300 test.cutoff: {"message":"hello","source_time":"2025-04-08T18:48:00+03:00"}
```

## Installation

### RubyGems

```
$ gem install fluent-plugin-time-cutoff
```

### Bundler

Add following line to your Gemfile:

```ruby
gem "fluent-plugin-time-cutoff"
```

And then execute:

```
$ bundle
```

## Configuration

``` xml
<filter **>
  @type time_cutoff
  @id time_cutoff
 
  old_cutoff 24h
  old_action pass
  old_log true

  new_cutoff 24h
  new_action pass
  new_log true

  source_time_key source_time
  source_time_format iso8601

  bad_time_action replace_timestamp
  bad_time_log true
  bad_time_key source_time_raw

  time_key_conflict skip
</filter>

```

### old_cutoff (time) (optional)

Records older than this amount of time are deemed "old". Defaults to 24 hours.

Must not be negative.

Default value: `86400`.

### old_action (enum) (optional)

The action that will be performed to all "old" messages. Defaults to passthrough.

Available values: pass, replace_timestamp, drop

Default value: `pass`.

### old_log (bool) (optional)

Log the "old" messages to Fluentd's own log. Defaults to "true".

Default value: `true`.

### new_cutoff (time) (optional)

Records newer than this amount of time are deemed "new". Defaults to 24 hours.

Must not be negative.

Default value: `86400`.

### new_action (enum) (optional)

The action that will be performed to all "new" messages. Defaults to passthrough.

Available values: pass, replace_timestamp, drop

Default value: `pass`.

### new_log (bool) (optional)

Log the "new" messages to Fluentd's own log. Defaults to "true".

Default value: `true`.

### source_time_key (string) (optional)

The key that will hold the original time (for :replace_timestamp action). Defaults to "source_time".

Must not be empty or equal to `bad_time_key`.

Default value: `source_time`.

### source_time_format (enum) (optional)

Time format for the original timestamp field. Defaults to ISO8601-formatted string.

Available values: epoch, epoch_float, iso8601

Default value: `iso8601`.

### bad_time_action (enum) (optional)

The action that will be performed to all messages with an unparseable time. Defaults to replacing it with current time.

Event times that aren't a `Fluent::EventTime` are parsed before the age check. Integers, floats, numeric strings and ISO 8601 datetime strings are accepted. ISO 8601 strings may use a space instead of `T` and may have a space before the timezone (e.g. `2025-04-08 14:43:14 +0300` or `2025-04-08 11:43:14 UTC`, as produced by Ruby's `Time#to_s`). Strings without a timezone are treated as local time. Any other time is deemed unparseable and is handled according to this action (and logged, unless `bad_time_log` is disabled).

Available values: replace_timestamp, drop

Default value: `replace_timestamp`.

### bad_time_log (bool) (optional)

Log the messages with an unparseable time to Fluentd's own log. Defaults to "true".

Default value: `true`.

### bad_time_key (string) (optional)

The key that will hold the original unparseable time (for :replace_timestamp action). Defaults to "source_time_raw".

Must not be empty or equal to `source_time_key`.

The original time is stored as is if it's a string, or as its Ruby `#inspect` representation otherwise (e.g. `nil`), so this field always holds a string. It is kept separate from `source_time_key`, so that `source_time_key` always holds a value in `source_time_format` and doesn't cause type conflicts in downstream storage.

Default value: `source_time_raw`.

### time_key_conflict (enum) (optional)

The action that will be performed when the record already has source_time_key or bad_time_key. Defaults to keeping the existing value.

This happens e.g. when a record passes through more than one `time_cutoff` filter, in which case the existing value is the true original time. The event time itself is replaced with current time in any case.

* `skip`: keep the existing value.
* `warn`: keep the existing value and log a warning to Fluentd's own log.
* `overwrite`: replace the existing value.

Available values: skip, warn, overwrite

Default value: `skip`.

## Copyright

* Copyright(c) 2025-2026 Qrator Labs and Serge Tkatchouk
* License: MIT
